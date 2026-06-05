# frozen_string_literal: true

module Przn
  module KittyText
    HEADING_SCALES = {
      1 => 4,
      2 => 3,
      3 => 2
    }.freeze

    module_function

    # Emit sized multicell text. The `s/w/n/d/v/h` params are standard kitty
    # OSC 66 (portable). The `f=` (font family) and `flip=` params are
    # Echoes-only extensions — when one of them is set AND we're running
    # inside Echoes, they ride on the private OSC 7772 ;multicell frame so
    # that strict kitty terminals never see unknown params on OSC 66.
    # Otherwise the extensions are silently dropped and we emit plain OSC
    # 66, which renders without the flip / custom font on any kitty-
    # compatible terminal (better than emitting an OSC 7772 frame the
    # terminal would ignore entirely).
    def sized(text, s:, h: nil, v: nil, n: nil, d: nil, f: nil, flip: nil, w: nil)
      params = +"s=#{s}"
      params << ":w=#{w}" if w
      params << ":n=#{n}" if n
      params << ":d=#{d}" if d
      params << ":h=#{h}" if h
      params << ":v=#{v}" if v

      if (f || flip) && echoes?
        params << ":f=#{f}" if f
        params << ":flip=#{flip}" if flip
        "\e]7772;multicell;#{params};#{text}\a"
      else
        "\e]66;#{params};#{text}\a"
      end
    end

    def echoes?
      ENV['TERM_PROGRAM'] == 'Echoes'
    end

    def heading(text, level:)
      scale = HEADING_SCALES[level]
      return text unless scale

      sized(text, s: scale, h: 1)
    end
  end
end
