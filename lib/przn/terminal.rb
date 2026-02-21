# frozen_string_literal: true

require 'io/console'

module Przn
  class Terminal
    def initialize(input: $stdin, output: $stdout)
      @in = input
      @out = output
    end

    def width  = @in.winsize[1]
    def height = @in.winsize[0]

    def cell_pixel_size
      @cell_pixel_size ||= query_cell_pixel_size || [10, 20]
    end

    def raw(&block) = @in.raw(&block)
    def getch       = @in.getch

    def write(str)
      @out.write(str)
    end

    def flush
      @out.flush
    end

    def clear
      write "\e[2J\e[H"
    end

    def move_to(row, col)
      write "\e[#{row};#{col}H"
    end

    def hide_cursor
      write "\e[?25l"
    end

    def show_cursor
      write "\e[?25h"
    end

    def enter_alt_screen
      write "\e[?1049h"
    end

    def leave_alt_screen
      write "\e[?1049l"
    end

    private

    def query_cell_pixel_size
      buf = "\0" * 8
      [0x40087468, 0x5413].each do |ioctl_code|
        begin
          @in.ioctl(ioctl_code, buf)
          rows, cols, xpixel, ypixel = buf.unpack('SSSS')
          if xpixel > 0 && ypixel > 0 && rows > 0 && cols > 0
            return [xpixel / cols, ypixel / rows]
          end
        rescue
          next
        end
      end
      nil
    end
  end
end
