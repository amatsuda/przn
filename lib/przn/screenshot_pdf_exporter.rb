# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

module Przn
  # Default PDF export: drives the live renderer, asks the terminal to save
  # each rendered slide as a one-page vector PDF via OSC 7772 `capture`,
  # then concatenates the per-slide PDFs into a single multi-page PDF.
  # Requires Echoes (or any terminal that implements the same capture
  # command); use `export_pdf_prawn` instead for environments where that's
  # not possible (CI, headless).
  def self.export_pdf(file, output, theme: nil)
    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    base_dir = File.dirname(File.expand_path(file))
    ScreenshotPdfExporter.new(presentation, base_dir: base_dir, theme: theme).export(output)
    puts "Generated: #{output}"
  end

  # Renders each slide live to the user's terminal, asks the terminal to save
  # the current pane as a vector PDF via Echoes' OSC 7772 `capture` command,
  # then concatenates the per-slide PDFs into a single multi-page PDF.
  #
  # Trade-off vs the Prawn-based PdfExporter:
  #   - Pixel-perfect match with what's on screen (gradients, fonts, OSC 66
  #     sized text, bullet glyphs, the lot) — but vector, so the result is
  #     small, sharp at any zoom, and text stays selectable.
  #   - Requires running inside a terminal that implements OSC 7772 capture
  #     to a `.pdf` path (i.e. Echoes). Won't work in CI or any terminal that
  #     doesn't honor the command.
  #
  # Echoes-side wire format (independent of przn):
  #   ESC ] 7772 ; capture ; <absolute_path> BEL
  #   On receipt, Echoes saves the current pane to the path. The file
  #   extension picks the format — `.pdf` produces a single-page vector PDF
  #   by replaying the same drawing pipeline into a CGPDFContext instead of
  #   the screen's NSGraphicsContext.
  class ScreenshotPdfExporter
    OSC = "\e]7772".freeze
    BEL = "\a".freeze

    POLL_INTERVAL = 0.05  # seconds between file-existence checks
    CAPTURE_TIMEOUT = 10  # seconds per slide before giving up

    def initialize(presentation, base_dir: '.', theme: nil, terminal: nil)
      @presentation = presentation
      @base_dir = base_dir
      @theme = theme || Theme.default
      @terminal = terminal || Terminal.new
      @renderer = Renderer.new(@terminal, base_dir: base_dir, theme: theme)
    end

    def export(output_path)
      require 'hexapdf'

      Dir.mktmpdir('przn-capture') do |dir|
        pdf_paths = capture_all_slides(dir)
        merge_pdfs(pdf_paths, output_path)
      end
    end

    private

    def capture_all_slides(dir)
      paths = []
      @terminal.enter_alt_screen
      @terminal.hide_cursor
      @presentation.slides.each_with_index do |slide, i|
        pdf_path = File.join(dir, format('slide-%04d.pdf', i))
        @renderer.render(slide, current: i, total: @presentation.total)
        request_capture(pdf_path)
        wait_for_capture(pdf_path)
        paths << pdf_path
      end
      paths
    ensure
      @terminal.write "#{OSC};bg-clear#{BEL}"
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
                'Is Echoes running and recent enough to honor OSC 7772 `capture` to a .pdf path?'
        end
        sleep POLL_INTERVAL
      end
      # Small grace period to ensure the PDF write is fully flushed.
      sleep POLL_INTERVAL
    end

    def merge_pdfs(pdf_paths, output_path)
      raise 'No slides captured' if pdf_paths.empty?

      output = HexaPDF::Document.new
      pdf_paths.each do |path|
        src = HexaPDF::Document.open(path)
        src.pages.each do |page|
          output.pages << output.import(page)
        end
      end
      output.write(output_path)
    end
  end
end
