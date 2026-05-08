# frozen_string_literal: true

module Przn
  class Controller
    def initialize(presentation, terminal, renderer)
      @presentation = presentation
      @terminal = terminal
      @renderer = renderer
      @preload_gen = 0
    end

    def run
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
          when 'q', "\x03"
            break
          end
        end
      end
    ensure
      @preload_gen += 1
      @preload_thread&.join
      @terminal.write "\e]7772;bg-clear\a"
      @terminal.show_cursor
      @terminal.leave_alt_screen
    end

    private

    def render_current
      @renderer.render(
        @presentation.current_slide,
        current: @presentation.current,
        total: @presentation.total
      )
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
