# frozen_string_literal: true

module Przn
  class Slide
    attr_reader :blocks, :layout, :attrs

    def initialize(blocks, layout: nil, attrs: {})
      @blocks = blocks.freeze
      @layout = layout
      @attrs = attrs.freeze
    end

    # Aggregate every `{::note}` / `<note>` segment in the slide's text-bearing
    # fields. The presenter view renders these in its side panel; the audience
    # renderer strips them from the rendered output.
    def notes
      out = []
      blocks.each do |b|
        texts = []
        texts << b[:content] if b[:content].is_a?(String)
        texts << b[:term]    if b[:term].is_a?(String)
        texts << b[:definition] if b[:definition].is_a?(String)
        if b[:items].is_a?(Array)
          b[:items].each { |it| texts << it[:text] if it.is_a?(Hash) && it[:text].is_a?(String) }
        end
        if b[:rows].is_a?(Array)
          (Array(b[:header]) + b[:rows].flatten).each { |c| texts << c if c.is_a?(String) }
        end
        texts.each do |text|
          Parser.parse_inline(text).each do |seg|
            out << seg[1] if seg[0] == :note && seg[1] && !seg[1].empty?
          end
        end
      end
      out
    end
  end
end
