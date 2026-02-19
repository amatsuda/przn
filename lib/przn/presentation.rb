# frozen_string_literal: true

module Przn
  class Presentation
    attr_reader :slides, :current

    def initialize(slides)
      @slides = slides.freeze
      @current = 0
    end

    def current_slide = slides[current]
    def total         = slides.size
    def first_slide?  = current == 0
    def last_slide?   = current == total - 1

    def next_slide
      @current = [current + 1, total - 1].min
    end

    def prev_slide
      @current = [current - 1, 0].max
    end

    def go_to(n)
      @current = n.clamp(0, total - 1)
    end

    def first_slide!
      @current = 0
    end

    def last_slide!
      @current = total - 1
    end
  end
end
