# frozen_string_literal: true

require_relative "przn/version"
require_relative "przn/kitty_text"
require_relative "przn/slide"
require_relative "przn/parser"
require_relative "przn/presentation"
require_relative "przn/terminal"
require_relative "przn/renderer"
require_relative "przn/controller"

module Przn
  class Error < StandardError; end

  def self.start(file)
    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    terminal = Terminal.new
    renderer = Renderer.new(terminal)
    Controller.new(presentation, terminal, renderer)
  end
end
