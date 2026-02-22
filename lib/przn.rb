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
require_relative "przn/pdf_exporter"

module Przn
  class Error < StandardError; end

  def self.start(file)
    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    terminal = Terminal.new
    base_dir = File.dirname(File.expand_path(file))
    renderer = Renderer.new(terminal, base_dir: base_dir)
    Controller.new(presentation, terminal, renderer)
  end

  def self.export_pdf(file, output)
    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    base_dir = File.dirname(File.expand_path(file))
    PdfExporter.new(presentation, base_dir: base_dir).export(output)
    puts "Generated: #{output}"
  end
end
