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

    def run
      @started_at = Time.now
      @terminal.enter_alt_screen
      @terminal.hide_cursor
      render_current

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

    # Kick off a background thread that pre-uploads images for the slides the
    # user is most likely to visit next (the immediate neighbors). Uses a
    # generation counter so a navigation that lands while a preload is still
    # running causes that preload to exit early instead of stacking work.
    def schedule_preload
      @preload_gen += 1
      gen = @preload_gen
      cur = @presentation.current
      total = @presentation.total
      indices = [cur + 1, cur - 1].select { |i| i.between?(0, total - 1) }
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
