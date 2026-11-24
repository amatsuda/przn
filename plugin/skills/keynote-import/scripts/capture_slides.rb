# frozen_string_literal: true

require 'przn'

module Przn
  # Renders every slide of a deck in the current Echoes pane and saves each
  # one as PNG through Echoes' OSC 7772 `capture` command. The PNG sibling
  # of ScreenshotPdfExporter: same render-then-capture loop, but one raster
  # file per slide so the result can be measured.
  #
  # usage (inside Echoes): bundle exec ruby capture_slides.rb DECK.md OUTDIR
  #
  # Writes OUTDIR/slide-N.png and OUTDIR/size.txt (columns, rows, cell size).
  # The PNGs carry the display's color profile; convert them to sRGB before
  # measuring. Image colors in the capture differ from what the screen
  # shows, so use the capture for geometry only.
  class SlideCapture
    OSC = "\e]7772".freeze
    BEL = "\a".freeze

    POLL_INTERVAL = 0.05  # seconds between file-existence checks
    CAPTURE_TIMEOUT = 10  # seconds per slide before giving up

    def initialize(file, output_dir, terminal: nil)
      @presentation = Parser.parse(File.read(file))
      @output_dir = output_dir
      @terminal = terminal || Terminal.new
      base_dir = File.dirname(File.expand_path(file))
      theme = Theme.auto_discover(near: file)
      @renderer = Renderer.new(@terminal, base_dir: base_dir, theme: theme, export_mode: true, presentation: @presentation)
    end

    def capture
      File.write(File.join(@output_dir, 'size.txt'), [@terminal.width, @terminal.height, @terminal.cell_pixel_size].inspect)
      capture_all_slides
    end

    private

    def capture_all_slides
      paths = []
      @terminal.enter_alt_screen
      @terminal.hide_cursor
      @presentation.slides.each_with_index do |slide, i|
        png_path = File.join(@output_dir, "slide-#{i + 1}.png")
        File.delete(png_path) if File.exist?(png_path)
        final_step = @renderer.step_count(slide) - 1
        @renderer.render(slide, current: i, total: @presentation.total, step: final_step)
        request_capture(png_path)
        wait_for_capture(png_path)
        paths << png_path
      end
      paths
    ensure
      @terminal.write "#{OSC};bg-clear#{BEL}"
      @terminal.write ImageUtil.kitty_clear_all if ImageUtil.kitty_terminal?
      @terminal.show_cursor
      @terminal.leave_alt_screen
      @terminal.flush
    end

    def request_capture(path)
      @terminal.write "#{OSC};capture;#{path}#{BEL}"
      @terminal.flush
    end

    def wait_for_capture(path)
      deadline = Time.now + CAPTURE_TIMEOUT
      until File.exist?(path) && File.size?(path).to_i.positive?
        if Time.now > deadline
          raise "Capture timed out for #{path}. " \
                'Is Echoes running and recent enough to honor OSC 7772 `capture` to a .png path?'
        end
        sleep POLL_INTERVAL
      end
      # Small grace period to ensure the PNG write is fully flushed.
      sleep POLL_INTERVAL
    end
  end
end

Przn::SlideCapture.new(*ARGV).capture
