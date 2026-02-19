# frozen_string_literal: true

module Przn
  module KittyText
    HEADING_SCALES = {
      1 => 4,
      2 => 3,
      3 => 2,
    }.freeze

    module_function

    def sized(text, s:, h: nil, v: nil)
      params = +"s=#{s}"
      params << ":h=#{h}" if h
      params << ":v=#{v}" if v
      "\e]66;#{params};#{text}\a"
    end

    def heading(text, level:)
      scale = HEADING_SCALES[level]
      return text unless scale

      sized(text, s: scale, h: 1)
    end
  end
end
