# frozen_string_literal: true

require 'strscan'

module Przn
  module Parser
    # Rabbit-compatible size names → Kitty text sizing scale
    SIZE_SCALES = {
      'xx-large' => 5,
      'x-large'  => 4,
      'large'    => 3,
      'small'    => 1,
      'x-small'  => 1,
      'xx-small' => 1,
    }.freeze

    NAMED_COLORS = {
      'red' => 31, 'green' => 32, 'yellow' => 33, 'blue' => 34,
      'magenta' => 35, 'cyan' => 36, 'white' => 37,
      'bright_red' => 91, 'bright_green' => 92, 'bright_yellow' => 93,
      'bright_blue' => 94, 'bright_magenta' => 95, 'bright_cyan' => 96,
      'bright_white' => 97,
    }.freeze

    module_function

    def parse(markdown)
      slides = split_slides(markdown)
      Presentation.new(slides.map { |raw| parse_slide(raw) })
    end

    def split_slides(markdown)
      chunks = []
      current = +""
      in_fence = false

      markdown.each_line do |line|
        if line.match?(/\A\s*```/)
          in_fence = !in_fence
          current << line
        elsif !in_fence && line.match?(/\A\s*---+\s*\z/)
          chunks << current
          current = +""
        else
          current << line
        end
      end
      chunks << current unless current.strip.empty?
      chunks
    end

    def parse_slide(raw)
      blocks = []
      lines = raw.lines
      i = 0

      while i < lines.size
        line = lines[i]

        case line
        when /\A\s*<!--\s*([\w\s=]+?)\s*-->\s*\z/
          attrs = parse_attrs(Regexp.last_match(1))
          blocks << {type: :style, **attrs} unless attrs.empty?
        when /\A\s*```(\w*)\s*\z/
          lang = Regexp.last_match(1)
          lang = nil if lang.empty?
          code_lines = []
          i += 1
          while i < lines.size && !lines[i].match?(/\A\s*```\s*\z/)
            code_lines << lines[i]
            i += 1
          end
          blocks << {type: :code_block, content: code_lines.join, language: lang}
        when /\A(\#{1,6})\s+(.*)/
          level = Regexp.last_match(1).size
          text = Regexp.last_match(2).strip
          blocks << {type: :heading, level: level, content: text}
        when /\A\s*>\s?(.*)/
          text = Regexp.last_match(1)
          blocks << {type: :blockquote, content: text}
        when /\A\s*[-*]\s+(.*)/
          items = [Regexp.last_match(1)]
          while (i + 1) < lines.size && lines[i + 1].match?(/\A\s*[-*]\s+/)
            i += 1
            items << lines[i].match(/\A\s*[-*]\s+(.*)/)[1]
          end
          blocks << {type: :unordered_list, items: items}
        when /\A\s*(\d+)\.\s+(.*)/
          items = [Regexp.last_match(2)]
          while (i + 1) < lines.size && lines[i + 1].match?(/\A\s*\d+\.\s+/)
            i += 1
            items << lines[i].match(/\A\s*\d+\.\s+(.*)/)[1]
          end
          blocks << {type: :ordered_list, items: items}
        when /\A\s*\z/
          blocks << {type: :blank}
        else
          blocks << {type: :paragraph, content: line.strip}
        end
        i += 1
      end

      Slide.new(blocks)
    end

    def parse_attrs(str)
      attrs = {}
      str.scan(/\S+/).each do |token|
        case token
        when /\As=(\d+)\z/
          attrs[:scale] = $1.to_i
        when 'b', 'bold'
          attrs[:bold] = true
        when 'i', 'italic'
          attrs[:italic] = true
        when /\A#([0-9a-fA-F]{6})\z/
          attrs[:color] = $1
        when /\Afg=(.+)\z/
          attrs[:color] = $1
        else
          attrs[:color] = token if NAMED_COLORS.key?(token)
        end
      end
      attrs
    end

    # Parse inline text, including Rabbit-style {::tag name="..."}...{:/tag}
    def parse_inline(text)
      segments = []
      scanner = StringScanner.new(text)

      until scanner.eos?
        if scanner.scan(/\{::tag\s+name="([^"]+)"\}(.*?)\{:\/tag\}/)
          segments << [:tag, scanner[2], scanner[1]]
        elsif scanner.scan(/`([^`]+)`/)
          segments << [:code, scanner[1]]
        elsif scanner.scan(/\*\*(.+?)\*\*/)
          segments << [:bold, scanner[1]]
        elsif scanner.scan(/\*(.+?)\*/)
          segments << [:italic, scanner[1]]
        elsif scanner.scan(/~~(.+?)~~/)
          segments << [:strikethrough, scanner[1]]
        else
          segments << [:text, scanner.scan(/[^`*~{]+|./)]
        end
      end

      segments
    end
  end
end
