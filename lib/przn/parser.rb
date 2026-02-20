# frozen_string_literal: true

require 'strscan'

module Przn
  module Parser
    # Size names → Kitty text sizing scale (1-7)
    SIZE_SCALES = {
      'xx-small' => 1,
      'x-small'  => 1,
      'small'    => 2,
      'large'    => 3,
      'x-large'  => 4,
      'xx-large' => 5,
      'xxx-large' => 6,
      'xxxx-large' => 7,
      '1' => 1, '2' => 2, '3' => 3, '4' => 4, '5' => 5, '6' => 6, '7' => 7,
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

    # Split on h1 headings (Rabbit-compatible)
    def split_slides(markdown)
      chunks = []
      current = +""
      in_fence = false

      markdown.each_line do |line|
        if line.match?(/\A\s*```/)
          in_fence = !in_fence
          current << line
        elsif !in_fence && line.match?(/\A#\s/)
          chunks << current unless current.strip.empty?
          current = +line
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
        # {::comment} ... {:/comment} block — skip entirely
        when /\A\s*\{::comment\}/
          i += 1
          i += 1 while i < lines.size && !lines[i].match?(/\{:\/comment\}/)

        # Block alignment: {:.center} or {:.right}
        when /\A\s*\{:\.(\w+)\}\s*\z/
          blocks << {type: :align, align: Regexp.last_match(1).to_sym}

        # Fenced code block
        when /\A\s*```(\w*)\s*\z/
          lang = Regexp.last_match(1)
          lang = nil if lang.empty?
          code_lines = []
          i += 1
          while i < lines.size && !lines[i].match?(/\A\s*```\s*\z/)
            code_lines << lines[i]
            i += 1
          end
          # Check for kramdown IAL on next line: {: lang="ruby"}
          if (i + 1) < lines.size && lines[i + 1]&.match?(/\A\s*\{:/)
            i += 1
            if lines[i].match(/lang="(\w+)"/)
              lang = Regexp.last_match(1)
            end
          end
          blocks << {type: :code_block, content: code_lines.join, language: lang}

        # Indented code block (4 spaces)
        when /\A {4}(.*)$/
          code_lines = [Regexp.last_match(1)]
          while (i + 1) < lines.size && lines[i + 1].match?(/\A {4}/)
            i += 1
            code_lines << lines[i].sub(/\A {4}/, '')
          end
          # Check for kramdown IAL: {: lang="ruby"}
          lang = nil
          if (i + 1) < lines.size && lines[i + 1]&.match?(/\A\s*\{:/)
            i += 1
            if lines[i].match(/lang="(\w+)"/)
              lang = Regexp.last_match(1)
            end
          end
          blocks << {type: :code_block, content: code_lines.join("\n") + "\n", language: lang}

        # h1 (slide title)
        when /\A#\s+(.*)/
          blocks << {type: :heading, level: 1, content: Regexp.last_match(1).strip}

        # h2-h6 (sub-headings within slide)
        when /\A(\#{2,6})\s+(.*)/
          level = Regexp.last_match(1).size
          text = Regexp.last_match(2).strip
          blocks << {type: :heading, level: level, content: text}

        # Block quote
        when /\A>\s?(.*)/
          quote_lines = [Regexp.last_match(1)]
          while (i + 1) < lines.size && (m = lines[i + 1].match(/\A>\s?(.*)/))
            i += 1
            quote_lines << m[1]
          end
          blocks << {type: :blockquote, content: quote_lines.join("\n")}

        # Table
        when /\A\|/
          table_lines = [line.strip]
          while (i + 1) < lines.size && lines[i + 1].match?(/\A\|/)
            i += 1
            table_lines << lines[i].strip
          end
          blocks << parse_table(table_lines)

        # Unordered list (* item)
        when /\A\*\s+(.*)/
          items = []
          while i < lines.size && (lines[i].match?(/\A\*\s+/) || lines[i].match?(/\A {2,}\*\s+/) || lines[i].match?(/\A {2,}\S/))
            if lines[i].match(/\A(\s*)\*\s+(.*)/)
              depth = Regexp.last_match(1).size / 2
              items << {text: Regexp.last_match(2), depth: depth}
            elsif lines[i].match(/\A {2,}(\S.*)/)
              # Continuation line
              items.last[:text] << " " << Regexp.last_match(1) if items.last
            else
              break
            end
            i += 1
          end
          i -= 1
          blocks << {type: :unordered_list, items: items}

        # Ordered list
        when /\A(\s*)\d+\.\s+(.*)/
          items = []
          while i < lines.size && lines[i].match?(/\A\s*\d+\.\s+/)
            lines[i].match(/\A(\s*)\d+\.\s+(.*)/)
            depth = Regexp.last_match(1).size / 3
            items << {text: Regexp.last_match(2), depth: depth}
            i += 1
          end
          i -= 1
          blocks << {type: :ordered_list, items: items}

        # Definition list: term on one line, :   definition on next
        when /\A(\S.*)\s*\z/
          if (i + 1) < lines.size && lines[i + 1].match?(/\A:\s{3}/)
            term = Regexp.last_match(1).strip
            i += 1
            definition_lines = []
            while i < lines.size && lines[i].match?(/\A:\s{3}(.*)|\A {4}(.*)/)
              if lines[i].match(/\A:\s{3}(.*)/)
                definition_lines << Regexp.last_match(1)
              elsif lines[i].match(/\A {4}(.*)/)
                definition_lines << Regexp.last_match(1)
              end
              i += 1
            end
            i -= 1
            blocks << {type: :definition_list, term: term, definition: definition_lines.join("\n")}
          else
            blocks << {type: :paragraph, content: Regexp.last_match(1).strip}
          end

        when /\A\s*\z/
          blocks << {type: :blank}

        else
          blocks << {type: :paragraph, content: line.strip}
        end
        i += 1
      end

      Slide.new(blocks)
    end

    def parse_table(lines)
      rows = []
      lines.each do |line|
        next if line.match?(/\A\|[-|:\s]+\|\s*\z/)  # separator row

        cells = line.split('|').map(&:strip).reject(&:empty?)
        rows << cells
      end
      {type: :table, header: rows.first, rows: rows.drop(1)}
    end

    # Parse inline text with Rabbit-compatible markup
    def parse_inline(text)
      segments = []
      scanner = StringScanner.new(text)

      until scanner.eos?
        if scanner.scan(/\{::tag\s+name="([^"]+)"\}(.*?)\{:\/tag\}/)
          segments << [:tag, scanner[2], scanner[1]]
        elsif scanner.scan(/\{::note\}(.*?)\{:\/note\}/)
          segments << [:note, scanner[1]]
        elsif scanner.scan(/\{::wait\/\}/)
          # skip wait markers in inline text
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
