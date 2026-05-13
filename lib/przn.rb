# frozen_string_literal: true

require_relative "przn/version"
require_relative "przn/kitty_text"
require_relative "przn/image_util"
require_relative "przn/slide"
require_relative "przn/parser"
require_relative "przn/presentation"
require_relative "przn/terminal"
require_relative "przn/renderer"
require_relative "przn/controller"
require_relative "przn/screenshot_pdf_exporter"
require_relative "przn/theme"

module Przn
  class Error < StandardError; end

  def self.start(file, theme: nil, start_at: nil)
    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    presentation.go_to(start_at - 1) if start_at
    terminal = Terminal.new
    base_dir = File.dirname(File.expand_path(file))
    renderer = Renderer.new(terminal, base_dir: base_dir, theme: theme)
    Controller.new(presentation, terminal, renderer)
  end

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
end
