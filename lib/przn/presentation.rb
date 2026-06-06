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

    # Deck-wide lookup for a block declared with `id="..."`. Used by
    # `<ref id="..."/>` to find the source block on another (or the
    # same) slide. Returns the source block hash, or nil when no
    # block with that id is found. First match by slide order wins;
    # `:ref` blocks themselves are excluded from the index so a chain
    # of refs doesn't resolve transitively in v1.
    def find_by_id(id)
      @by_id ||= build_id_index
      @by_id[id.to_s]
    end

    private

    def build_id_index
      index = {}
      @slides.each do |slide|
        slide.blocks.each do |b|
          next if b[:type] == :ref
          a = b[:attrs]
          next unless a
          # Parser key style is split: `:at` and shapes keep symbols
          # from parse_xml_attrs, while `:image` (and any other block
          # that runs `transform_keys(&:to_s)`) stores string keys.
          # Check both — same as compute_effective_state's by_id build.
          bid = a['id'] || a[:id]
          next unless bid
          index[bid.to_s] ||= b
        end
      end
      index
    end
  end
end
