# frozen_string_literal: true

module Przn
  class Controller
    def initialize(presentation, terminal, renderer)
      @presentation = presentation
      @terminal = terminal
      @renderer = renderer
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
