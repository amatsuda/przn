# frozen_string_literal: true

module Przn
  class Renderer
    ANSI = {
      bold:          "\e[1m",
      italic:        "\e[3m",
      reverse:       "\e[7m",
      strikethrough: "\e[9m",
      dim:           "\e[2m",
      cyan:          "\e[36m",
      gray_bg:       "\e[48;5;236m",
      reset:         "\e[0m",
    }.freeze

    DEFAULT_SCALE = 2

    def initialize(terminal)
      @terminal = terminal
    end

    def render(slide, current:, total:)
      @terminal.clear
      w = @terminal.width
      h = @terminal.height

      row = if current == 0
        content_height = calculate_height(slide.blocks)
        usable_height = h - 1
        [(usable_height - content_height) / 2 + 1, 1].max
      else
        2
      end

      pending_align = nil
      slide.blocks.each do |block|
        if block[:type] == :align
          pending_align = block[:align]
        else
          row = render_block(block, w, row, align: pending_align)
          pending_align = nil
        end
      end

      status = " #{current + 1} / #{total} "
      @terminal.move_to(h, w - status.size)
      @terminal.write "#{ANSI[:dim]}#{status}#{ANSI[:reset]}"

      @terminal.flush
    end

    private

    def render_block(block, width, row, align: nil)
      case block[:type]
      when :heading         then render_heading(block, width, row)
      when :paragraph       then render_paragraph(block, width, row, align: align)
      when :code_block      then render_code_block(block, width, row)
      when :unordered_list  then render_unordered_list(block, width, row)
      when :ordered_list    then render_ordered_list(block, width, row)
      when :definition_list then render_definition_list(block, width, row)
      when :blockquote      then render_blockquote(block, width, row)
      when :table           then render_table(block, width, row)
      when :blank           then row + DEFAULT_SCALE
      else row + 1
      end
    end

    def render_heading(block, width, row)
      text = block[:content]

      if block[:level] == 1
        scale = KittyText::HEADING_SCALES[1]
        visible_width = display_width(text) * scale
        pad = [(width - visible_width) / 2, 0].max
        @terminal.move_to(row, pad + 1)
        @terminal.write "#{ANSI[:bold]}#{KittyText.sized(text, s: scale)}#{ANSI[:reset]}"
        row + scale + 1
      else
        left = content_left(width)
        @terminal.move_to(row, left)
        @terminal.write "#{KittyText.sized("・", s: DEFAULT_SCALE)}#{render_inline_scaled(text, DEFAULT_SCALE)}"
        row + DEFAULT_SCALE
      end
    end

    def render_paragraph(block, width, row, align: nil)
      text = block[:content]
      scale = max_inline_scale(text) || DEFAULT_SCALE
      left = content_left(width)

      if align
        vis = visible_width_scaled(text, scale)
        left = compute_pad(width, vis, align)
      end

      @terminal.move_to(row, left + 1)
      @terminal.write render_inline_scaled(text, scale)
      row + scale
    end

    def render_code_block(block, width, row)
      code_lines = block[:content].lines.map(&:chomp)
      return row + DEFAULT_SCALE if code_lines.empty?

      left = content_left(width)
      max_len = code_lines.map(&:size).max
      box_width = [max_len + 4, width - left - 4].min

      code_lines.each do |code_line|
        padded = code_line.ljust(box_width - 4)
        @terminal.move_to(row, left + 1)
        @terminal.write "#{ANSI[:gray_bg]}#{KittyText.sized("  #{padded}  ", s: DEFAULT_SCALE)}#{ANSI[:reset]}"
        row += DEFAULT_SCALE
      end

      row
    end

    def render_unordered_list(block, width, row)
      left = content_left(width)
      block[:items].each do |item|
        indent = "  " * (item[:depth] || 0)
        @terminal.move_to(row, left)
        @terminal.write "#{KittyText.sized("#{indent}・", s: DEFAULT_SCALE)}#{render_inline_scaled(item[:text], DEFAULT_SCALE)}"
        row += DEFAULT_SCALE
      end
      row
    end

    def render_ordered_list(block, width, row)
      left = content_left(width)
      block[:items].each_with_index do |item, i|
        indent = "  " * (item[:depth] || 0)
        @terminal.move_to(row, left)
        @terminal.write "#{KittyText.sized("#{indent}#{i + 1}. ", s: DEFAULT_SCALE)}#{render_inline_scaled(item[:text], DEFAULT_SCALE)}"
        row += DEFAULT_SCALE
      end
      row
    end

    def render_definition_list(block, width, row)
      left = content_left(width)
      @terminal.move_to(row, left)
      @terminal.write "#{ANSI[:bold]}#{render_inline_scaled(block[:term], DEFAULT_SCALE)}#{ANSI[:reset]}"
      row += DEFAULT_SCALE
      block[:definition].each_line do |line|
        @terminal.move_to(row, left + 4)
        @terminal.write render_inline_scaled(line.chomp, DEFAULT_SCALE)
        row += DEFAULT_SCALE
      end
      row
    end

    def render_blockquote(block, width, row)
      left = content_left(width)
      block[:content].each_line do |line|
        text = line.chomp
        @terminal.move_to(row, left + 1)
        @terminal.write "#{ANSI[:dim]}#{KittyText.sized("| #{text}", s: DEFAULT_SCALE)}#{ANSI[:reset]}"
        row += DEFAULT_SCALE
      end
      row
    end

    def render_table(block, width, row)
      left = content_left(width)
      all_rows = [block[:header]] + block[:rows]
      col_widths = Array.new(block[:header]&.size || 0, 0)
      all_rows.each do |cells|
        cells&.each_with_index do |cell, ci|
          col_widths[ci] = [col_widths[ci] || 0, cell.size].max
        end
      end

      all_rows.each_with_index do |cells, ri|
        next unless cells

        @terminal.move_to(row, left)
        line = cells.each_with_index.map { |cell, ci|
          cell.ljust(col_widths[ci] || 0)
        }.join("  |  ")
        if ri == 0
          @terminal.write "#{ANSI[:bold]}#{KittyText.sized(line, s: DEFAULT_SCALE)}#{ANSI[:reset]}"
        else
          @terminal.write KittyText.sized(line, s: DEFAULT_SCALE)
        end
        row += DEFAULT_SCALE

        if ri == 0
          @terminal.move_to(row, left)
          @terminal.write KittyText.sized(col_widths.map { |w| "-" * w }.join("--+--"), s: DEFAULT_SCALE)
          row += DEFAULT_SCALE
        end
      end
      row
    end

    def content_left(width)
      width / 8
    end

    def compute_pad(width, content_width, align)
      case align
      when :right  then [(width - content_width - 2), 0].max
      when :center then [(width - content_width) / 2, 0].max
      else content_left(width)
      end
    end

    def render_inline(text)
      Parser.parse_inline(text).map { |segment|
        type = segment[0]
        content = segment[1]
        case type
        when :tag           then render_tag(content, segment[2])
        when :note          then "#{ANSI[:dim]}#{content}#{ANSI[:reset]}"
        when :bold          then "#{ANSI[:bold]}#{content}#{ANSI[:reset]}"
        when :italic        then "#{ANSI[:italic]}#{content}#{ANSI[:reset]}"
        when :strikethrough then "#{ANSI[:strikethrough]}#{content}#{ANSI[:reset]}"
        when :code          then "#{ANSI[:gray_bg]} #{content} #{ANSI[:reset]}"
        when :text          then content
        end
      }.join
    end

    def render_tag(text, tag_name)
      if (scale = Parser::SIZE_SCALES[tag_name])
        KittyText.sized(text, s: scale)
      elsif Parser::NAMED_COLORS.key?(tag_name)
        "#{color_code(tag_name)}#{text}#{ANSI[:reset]}"
      else
        text
      end
    end

    def render_inline_scaled(text, para_scale)
      Parser.parse_inline(text).map { |segment|
        type = segment[0]
        content = segment[1]
        case type
        when :tag
          tag_name = segment[2]
          if (scale = Parser::SIZE_SCALES[tag_name])
            KittyText.sized(content, s: scale)
          elsif Parser::NAMED_COLORS.key?(tag_name)
            "#{color_code(tag_name)}#{content}#{ANSI[:reset]}"
          else
            KittyText.sized(content, s: para_scale)
          end
        when :note          then "#{ANSI[:dim]}#{KittyText.sized(content, s: para_scale)}#{ANSI[:reset]}"
        when :bold          then "#{ANSI[:bold]}#{KittyText.sized(content, s: para_scale)}#{ANSI[:reset]}"
        when :italic        then "#{ANSI[:italic]}#{KittyText.sized(content, s: para_scale)}#{ANSI[:reset]}"
        when :strikethrough then "#{ANSI[:strikethrough]}#{KittyText.sized(content, s: para_scale)}#{ANSI[:reset]}"
        when :code          then "#{ANSI[:gray_bg]}#{KittyText.sized(" #{content} ", s: para_scale)}#{ANSI[:reset]}"
        when :text          then KittyText.sized(content, s: para_scale)
        end
      }.join
    end

    def max_inline_scale(text)
      max = 0
      text.scan(/\{::tag\s+name="([^"]+)"\}/) do
        scale = Parser::SIZE_SCALES[$1]
        max = scale if scale && scale > max
      end
      max > 0 ? max : nil
    end

    def visible_width_scaled(text, default_scale)
      Parser.parse_inline(text).sum { |segment|
        type = segment[0]
        content = segment[1]
        case type
        when :tag
          scale = Parser::SIZE_SCALES[segment[2]] || default_scale
          display_width(content) * scale
        else
          display_width(content) * default_scale
        end
      }
    end

    def color_code(color)
      if (code = Parser::NAMED_COLORS[color])
        "\e[#{code}m"
      elsif color.match?(/\A[0-9a-fA-F]{6}\z/)
        r, g, b = color.scan(/../).map { |h| h.to_i(16) }
        "\e[38;2;#{r};#{g};#{b}m"
      else
        ""
      end
    end

    def visible_length(text)
      display_width(strip_markup(text))
    end

    # Calculate display width accounting for double-width CJK characters
    def display_width(str)
      str.each_char.sum { |c|
        o = c.ord
        if o >= 0x1100 &&
            (o <= 0x115f || # Hangul Jamo
             o == 0x2329 || o == 0x232a ||
             (o >= 0x2e80 && o <= 0x303e) || # CJK Radicals..CJK Symbols
             (o >= 0x3040 && o <= 0x33bf) || # Hiragana..CJK Compatibility
             (o >= 0x3400 && o <= 0x4dbf) || # CJK Unified Ext A
             (o >= 0x4e00 && o <= 0xa4cf) || # CJK Unified..Yi Radicals
             (o >= 0xac00 && o <= 0xd7a3) || # Hangul Syllables
             (o >= 0xf900 && o <= 0xfaff) || # CJK Compatibility Ideographs
             (o >= 0xfe30 && o <= 0xfe6f) || # CJK Compatibility Forms
             (o >= 0xff00 && o <= 0xff60) || # Fullwidth Forms
             (o >= 0xffe0 && o <= 0xffe6) ||
             (o >= 0x20000 && o <= 0x2fffd) ||
             (o >= 0x30000 && o <= 0x3fffd))
          2
        else
          1
        end
      }
    end

    def strip_markup(text)
      text
        .gsub(/\{::tag\s+name="[^"]+"\}(.*?)\{:\/tag\}/, '\1')
        .gsub(/\{::note\}(.*?)\{:\/note\}/, '\1')
        .gsub(/\{::wait\/\}/, '')
        .gsub(/\*\*(.+?)\*\*/, '\1')
        .gsub(/\*(.+?)\*/, '\1')
        .gsub(/~~(.+?)~~/, '\1')
        .gsub(/`([^`]+)`/, '\1')
    end

    def calculate_height(blocks)
      blocks.sum { |b| block_height(b) }
    end

    def block_height(block)
      s = DEFAULT_SCALE
      case block[:type]
      when :heading
        scale = KittyText::HEADING_SCALES[block[:level]] || s
        block[:level] == 1 ? scale + 1 : scale
      when :paragraph
        max_inline_scale(block[:content]) || s
      when :code_block
        [block[:content].lines.size * s, s].max
      when :unordered_list
        block[:items].size * s
      when :ordered_list
        block[:items].size * s
      when :definition_list
        (1 + block[:definition].lines.size) * s
      when :blockquote
        block[:content].lines.size * s
      when :table
        ((block[:header] ? 2 : 0) + block[:rows].size) * s
      when :align
        0
      when :blank
        s
      else
        s
      end
    end
  end
end
