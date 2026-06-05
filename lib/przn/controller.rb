# frozen_string_literal: true

module Przn
  class Controller
    # `source_file:` / `theme_path:` enable the `r` key to re-read the
    # deck (and the theme.yml, if one is in play) from disk so authors
    # can iterate on the markdown without restarting the session.
    # `theme_path` is the explicit `--theme PATH` value; when nil, the
    # auto-discover path is re-run on each reload (so dropping a
    # `theme.yml` next to the deck mid-session also takes effect).
    def initialize(presentation, terminal, renderer, audience_link: nil,
                   source_file: nil, theme_path: nil)
      @presentation = presentation
      @terminal = terminal
      @renderer = renderer
      @audience_link = audience_link
      @source_file = source_file
      @theme_path = theme_path
      @preload_gen = 0
    end

    # Seconds between runner-bar refresh ticks. The 🐢 only crawls
    # across the track over the full talk's duration, so once a second
    # is plenty for visible movement without being noisy.
    RUNNER_BAR_TICK_SECONDS = 1.0

    def run
      @started_at = Time.now
      @terminal.enter_alt_screen
      @terminal.hide_cursor
      render_current
      start_runner_bar_thread

      @terminal.raw do
        loop do
          case read_key
          when :right, :down, 'l', 'j', ' '
            @presentation.next_slide
            render_current
          when :left, :up, 'h', 'k'
            @presentation.prev_slide
            render_current
          when 'g'
            @presentation.first_slide!
            render_current
          when 'G'
            @presentation.last_slide!
            render_current
          when 'r'
            reload
          when 'q', "\x03"
            break
          end
        end
      end
    ensure
      stop_runner_bar_thread
      @preload_gen += 1
      @preload_thread&.join
      if @audience_link
        AudienceLink.send(@audience_link, type: "quit")
        @audience_link.close
      end
      @terminal.write "\e]7772;bg-clear\a"
      @terminal.write ImageUtil.kitty_clear_all if ImageUtil.kitty_terminal?
      @terminal.show_cursor
      @terminal.leave_alt_screen
    end

    private

    # Re-read the source markdown (and theme.yml, if any) from disk
    # and re-render. Stays on the current slide index, clamped to the
    # new deck's bounds. Any IO / parse error is swallowed so a bad
    # save mid-edit doesn't kill the running session — the user just
    # sees the previous slide until the next reload succeeds.
    def reload
      return unless @source_file
      markdown = File.read(@source_file)
      new_presentation = Parser.parse(markdown)
      return if new_presentation.total.zero?

      new_theme =
        if @theme_path
          Theme.load(@theme_path)
        else
          Theme.auto_discover(near: @source_file)
        end
      # auto_discover returns nil when no theme.yml sits next to the
      # deck; fall back to Theme.default so the renderer never has a
      # nil theme (matching what Renderer#initialize does on first
      # construction).
      new_theme ||= Theme.default

      new_presentation.go_to([@presentation.current, new_presentation.total - 1].min)
      @presentation = new_presentation
      @renderer.theme = new_theme
      render_current
    rescue StandardError
      # Don't crash the session on a bad edit; keep showing the old deck.
    end

    def render_current
      @renderer.render(
        @presentation.current_slide,
        current: @presentation.current,
        total: @presentation.total,
        started_at: @started_at
      )
      if @audience_link
        AudienceLink.send(@audience_link,
                          type: "goto",
                          index: @presentation.current,
                          started_at: @started_at.to_f)
      end
      schedule_preload
    end

    # Number of slides on each side of the current slide to pre-upload
    # in the background. Higher = snappier multi-step navigation but
    # more startup work per slide change (and more memory tied up in
    # Echoes' image cache). 3 covers the "I'm about to skip a couple
    # of slides ahead" case without crowding out the LRU when shape-
    # heavy decks have lots of image_ids per slide.
    PRELOAD_RADIUS = 3

    # Kick off a background thread that pre-uploads images for the slides the
    # user is most likely to visit next. Walks PRELOAD_RADIUS slides in each
    # direction, interleaved (next, prev, next+1, prev+1, …) so the most-
    # likely visit gets warmed first if the user keys quickly. Uses a
    # generation counter so a navigation that lands while a preload is still
    # running causes that preload to exit early instead of stacking work.
    def schedule_preload
      @preload_gen += 1
      gen = @preload_gen
      cur = @presentation.current
      total = @presentation.total
      indices = (1..PRELOAD_RADIUS).flat_map { |d| [cur + d, cur - d] }
                                    .select { |i| i.between?(0, total - 1) }
      return if indices.empty?

      @preload_thread = Thread.new do
        indices.each do |idx|
          break if gen != @preload_gen
          @renderer.preload(@presentation.slides[idx])
        end
      rescue StandardError
        # Background work must not crash the presentation.
      end
    end

    # Spawn a thread that calls `redraw_runner_bar` once per second so
    # the 🐢 turtle visibly crawls across the screen against real time
    # instead of only updating on slide navigation. No-op when the
    # theme didn't opt into the runner bar (no `counter.duration`) or
    # we're in export / audience-only modes.
    def start_runner_bar_thread
      return unless runner_bar_thread_eligible?
      @runner_bar_stop = false
      @runner_bar_thread = Thread.new do
        until @runner_bar_stop
          sleep RUNNER_BAR_TICK_SECONDS
          break if @runner_bar_stop
          begin
            @renderer.redraw_runner_bar(
              current: @presentation.current,
              total: @presentation.total,
              started_at: @started_at
            )
          rescue StandardError
            # Background work must not crash the presentation.
          end
        end
      end
    end

    def stop_runner_bar_thread
      @runner_bar_stop = true
      # Wake the sleep so the thread exits promptly instead of waiting
      # out the full tick interval on quit.
      @runner_bar_thread&.wakeup rescue nil
      @runner_bar_thread&.join
    end

    def runner_bar_thread_eligible?
      return false unless @renderer.respond_to?(:redraw_runner_bar)
      return false if @renderer.respond_to?(:export_mode) && @renderer.export_mode
      theme = @renderer.respond_to?(:theme) ? @renderer.theme : nil
      return false unless theme
      counter = theme.counter
      duration = counter && counter[:duration]
      duration && Theme.parse_duration(duration).to_i.positive?
    end

    def read_key
      c = $stdin.getc
      return nil unless c

      if c == "\e"
        seq = $stdin.read_nonblock(2)
        case seq
        when '[A' then :up
        when '[B' then :down
        when '[C' then :right
        when '[D' then :left
        when '[H' then :home
        when '[F' then :end
        else :escape
        end
      else
        c
      end
    rescue IO::WaitReadable
      :escape
    end
  end
end
