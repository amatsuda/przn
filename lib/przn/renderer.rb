# frozen_string_literal: true

module Przn
  class Renderer
    ANSI = {
      bold:    "\e[1m",
      italic:  "\e[3m",
      reverse:       "\e[7m",
      strikethrough: "\e[9m",
      dim:     "\e[2m",
      cyan:    "\e[36m",
      gray_bg: "\e[48;5;236m",
      reset:   "\e[0m",
    }.freeze

    def initialize(terminal)
      @terminal = terminal
    end

    def render(slide, current:, total:)
      @terminal.clear
      w = @terminal.width
      h = @terminal.height

      content_height = calculate_height(slide.blocks)
      usable_height = h - 1
      row = [(usable_height - content_height) / 2 + 1, 1].max

      pending_style = nil
      slide.blocks.each do |block|
        if block[:type] == :style
          pending_style = block
        else
          row = render_block(block, w, row, style: pending_style)
          pending_style = nil
        end
      end

      status = " #{current + 1} / #{total} "
      @terminal.move_to(h, w - status.size)
      @terminal.write "#{ANSI[:dim]}#{status}#{ANSI[:reset]}"

      @terminal.flush
    end

    private

    def render_block(block, width, row, style: nil)
      case block[:type]
      when :heading        then render_heading(block, width, row)
      when :paragraph      then render_paragraph(block, width, row, style: style)
      when :code_block     then render_code_block(block, width, row)
      when :unordered_list then render_unordered_list(block, width, row)
      when :ordered_list   then render_ordered_list(block, width, row)
      when :blockquote     then render_blockquote(block, width, row)
      else row + 1
      end
    end

    def render_heading(block, width, row)
      text = block[:content]
      scale = KittyText::HEADING_SCALES[block[:level]]

      if scale
        visible_width = text.size * scale
        pad = [(width - visible_width) / 2, 0].max
        @terminal.move_to(row, pad + 1)
        @terminal.write "#{ANSI[:bold]}#{KittyText.sized(text, s: scale)}#{ANSI[:reset]}"
        row + scale
      else
        pad = [(width - text.size) / 2, 0].max
        @terminal.move_to(row, pad + 1)
        @terminal.write "#{ANSI[:bold]}#{text}#{ANSI[:reset]}"
        row + 1
      end
    end

    def render_paragraph(block, width, row, style: nil)
      text = block[:content]
      scale = style&.[](:scale) || max_inline_scale(text)
      bold = style&.[](:bold)
      italic = style&.[](:italic)
      color = style&.[](:color)

      # Build ANSI prefix/suffix to wrap OUTSIDE any OSC 66 sequence
      ansi_pre = +""
      ansi_pre << ANSI[:bold] if bold
      ansi_pre << ANSI[:italic] if italic
      ansi_pre << color_code(color) if color
      ansi_post = (bold || italic || color) ? ANSI[:reset] : ""

      if scale
        visible_width = visible_width_scaled(text, scale)
        pad = [(width - visible_width) / 2, 0].max
        @terminal.move_to(row, pad + 1)
        @terminal.write "#{ansi_pre}#{render_inline_scaled(text, scale)}#{ansi_post}"
        row + scale
      else
        pad = [(width - visible_length(text)) / 2, 0].max
        @terminal.move_to(row, pad + 1)
        @terminal.write "#{ansi_pre}#{render_inline(text)}#{ansi_post}"
        row + 1
      end
    end

    def render_code_block(block, width, row)
      code_lines = block[:content].lines.map(&:chomp)
      return row + 1 if code_lines.empty?

      max_len = code_lines.map(&:size).max
      box_width = [max_len + 4, width - 8].min
      left_pad = [(width - box_width) / 2, 0].max

      code_lines.each do |code_line|
        padded = code_line.ljust(box_width - 4)
        @terminal.move_to(row, left_pad + 1)
        @terminal.write "#{ANSI[:gray_bg]}  #{padded}  #{ANSI[:reset]}"
        row += 1
      end

      row
    end

    def render_unordered_list(block, width, row)
      left = width / 4
      block[:items].each do |item|
        @terminal.move_to(row, left)
        @terminal.write "・#{render_inline(item)}"
        row += 1
      end
      row
    end

    def render_ordered_list(block, width, row)
      left = width / 4
      block[:items].each_with_index do |item, i|
        @terminal.move_to(row, left)
        @terminal.write "#{i + 1}. #{render_inline(item)}"
        row += 1
      end
      row
    end

    def render_blockquote(block, width, row)
      text = block[:content]
      visible = "  | #{text}"
      pad = [(width - visible.size) / 2, 0].max
      @terminal.move_to(row, pad + 1)
      @terminal.write "  #{ANSI[:dim]}| #{text}#{ANSI[:reset]}"
      row + 1
    end

    def render_inline(text)
      Parser.parse_inline(text).map { |segment|
        type = segment[0]
        content = segment[1]
        case type
        when :tag
          tag_name = segment[2]
          render_tag(content, tag_name)
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

    # Render paragraph where the max scale is already known.
    # Each segment is rendered at its own scale (from tag) or at the
    # paragraph-level scale; plain text outside tags uses the given scale.
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
        when :bold          then "#{ANSI[:bold]}#{KittyText.sized(content, s: para_scale)}#{ANSI[:reset]}"
        when :italic        then "#{ANSI[:italic]}#{KittyText.sized(content, s: para_scale)}#{ANSI[:reset]}"
        when :strikethrough then "#{ANSI[:strikethrough]}#{KittyText.sized(content, s: para_scale)}#{ANSI[:reset]}"
        when :code          then "#{ANSI[:gray_bg]}#{KittyText.sized(" #{content} ", s: para_scale)}#{ANSI[:reset]}"
        when :text          then KittyText.sized(content, s: para_scale)
        end
      }.join
    end

    # Detect the max scale from inline {::tag name="..."} in text.
    # Returns nil if no size tags found.
    def max_inline_scale(text)
      max = 0
      text.scan(/\{::tag\s+name="([^"]+)"\}/) do
        scale = Parser::SIZE_SCALES[$1]
        max = scale if scale && scale > max
      end
      max > 0 ? max : nil
    end

    # Calculate visible width accounting for scale
    def visible_width_scaled(text, default_scale)
      segments = Parser.parse_inline(text)
      segments.sum { |segment|
        type = segment[0]
        content = segment[1]
        case type
        when :tag
          tag_name = segment[2]
          scale = Parser::SIZE_SCALES[tag_name] || default_scale
          content.size * scale
        else
          content = strip_markup(content) if type != :text
          content.size * default_scale
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
      strip_markup(text).size
    end

    def strip_markup(text)
      text
        .gsub(/\{::tag\s+name="[^"]+"\}(.*?)\{:\/tag\}/, '\1')
        .gsub(/\*\*(.+?)\*\*/, '\1')
        .gsub(/\*(.+?)\*/, '\1')
        .gsub(/~~(.+?)~~/, '\1')
        .gsub(/`([^`]+)`/, '\1')
    end

    def calculate_height(blocks)
      height = 0
      pending_style = nil
      blocks.each do |block|
        if block[:type] == :style
          pending_style = block
        else
          height += block_height(block, style: pending_style)
          pending_style = nil
        end
      end
      height
    end

    def block_height(block, style: nil)
      case block[:type]
      when :heading
        KittyText::HEADING_SCALES[block[:level]] || 1
      when :paragraph
        style&.[](:scale) || max_inline_scale(block[:content]) || 1
      when :code_block
        [block[:content].lines.size, 1].max
      when :unordered_list
        block[:items].size
      when :ordered_list
        block[:items].size
      else
        1
      end
    end
  end
end
