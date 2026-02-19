# frozen_string_literal: true

module Przn
  class Slide
    attr_reader :blocks

    def initialize(blocks)
      @blocks = blocks.freeze
    end
  end
end
