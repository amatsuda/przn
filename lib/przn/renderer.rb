# frozen_string_literal: true

module Przn
  class Renderer
    ANSI = {
      bold:    "\e[1m",
      italic:  "\e[3m",
      reverse: "\e[7m",
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

      slide.blocks.each do |block|
        row = render_block(block, w, row)
      end

      status = " #{current + 1} / #{total} "
      @terminal.move_to(h, w - status.size)
      @terminal.write "#{ANSI[:dim]}#{status}#{ANSI[:reset]}"

      @terminal.flush
    end

    private

    def render_block(block, width, row)
      case block[:type]
      when :heading        then render_heading(block, width, row)
      when :paragraph      then render_paragraph(block, width, row)
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

    def render_paragraph(block, width, row)
      text = block[:content]
      pad = [(width - visible_length(text)) / 2, 0].max
      @terminal.move_to(row, pad + 1)
      @terminal.write render_inline(text)
      row + 1
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
      Parser.parse_inline(text).map { |(type, content)|
        case type
        when :bold   then "#{ANSI[:bold]}#{content}#{ANSI[:reset]}"
        when :italic then "#{ANSI[:italic]}#{content}#{ANSI[:reset]}"
        when :code   then "#{ANSI[:gray_bg]} #{content} #{ANSI[:reset]}"
        when :text   then content
        end
      }.join
    end

    def visible_length(text)
      strip_markup(text).size
    end

    def strip_markup(text)
      text.gsub(/\*\*(.+?)\*\*/, '\1').gsub(/\*(.+?)\*/, '\1').gsub(/`([^`]+)`/, '\1')
    end

    def calculate_height(blocks)
      blocks.sum { |b| block_height(b) }
    end

    def block_height(block)
      case block[:type]
      when :heading
        KittyText::HEADING_SCALES[block[:level]] || 1
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
