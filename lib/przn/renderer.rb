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

    def initialize(terminal, base_dir: '.', theme: nil)
      @terminal = terminal
      @base_dir = base_dir
      @theme = theme
    end

    def render(slide, current:, total:)
      @terminal.clear
      w = @terminal.width
      h = @terminal.height

      row = if current == 0
        content_height = calculate_height(slide.blocks, w)
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
      when :image           then render_image(block, width, row)
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
        row + scale + 4
      else
        left = content_left(width)
        prefix = "・"
        prefix_w = display_width(prefix)
        max_w = max_text_width(width, left, DEFAULT_SCALE) - prefix_w
        segments = Parser.parse_inline(text)
        wrapped = wrap_segments(segments, max_w)

        wrapped.each_with_index do |line_segs, li|
          @terminal.move_to(row, left)
          if li == 0
            @terminal.write "#{KittyText.sized(prefix, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          else
            @terminal.write "#{KittyText.sized(" " * prefix_w, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          end
          row += DEFAULT_SCALE
        end
        row
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

      max_w = max_text_width(width, left, scale)
      segments = Parser.parse_inline(text)
      wrapped = wrap_segments(segments, max_w)

      wrapped.each do |line_segs|
        @terminal.move_to(row, left + 1)
        @terminal.write render_segments_scaled(line_segs, scale)
        row += scale
      end
      row
    end

    def render_code_block(block, width, row)
      code_lines = block[:content].lines.map(&:chomp)
      return row + DEFAULT_SCALE if code_lines.empty?

      left = content_left(width)
      max_content_w = max_text_width(width, left, DEFAULT_SCALE) - 4
      max_len = code_lines.map { |l| display_width(l) }.max
      box_content_w = [max_len, max_content_w].min

      code_lines.each do |code_line|
        truncated = truncate_to_width(code_line, box_content_w)
        padded = pad_to_width(truncated, box_content_w)
        @terminal.move_to(row, left + 1)
        @terminal.write "#{ANSI[:gray_bg]}#{KittyText.sized("  #{padded}  ", s: DEFAULT_SCALE)}#{ANSI[:reset]}"
        row += DEFAULT_SCALE
      end

      row
    end

    def render_unordered_list(block, width, row)
      left = content_left(width)
      block[:items].each do |item|
        depth = item[:depth] || 0
        indent = "  " * depth
        prefix = "#{indent}・"
        prefix_w = display_width(prefix)
        max_w = max_text_width(width, left, DEFAULT_SCALE) - prefix_w

        segments = Parser.parse_inline(item[:text])
        wrapped = wrap_segments(segments, max_w)

        wrapped.each_with_index do |line_segs, li|
          @terminal.move_to(row, left)
          if li == 0
            @terminal.write "#{KittyText.sized(prefix, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          else
            @terminal.write "#{KittyText.sized(" " * prefix_w, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          end
          row += DEFAULT_SCALE
        end
        row += 1
      end
      row
    end

    def render_ordered_list(block, width, row)
      left = content_left(width)
      block[:items].each_with_index do |item, i|
        depth = item[:depth] || 0
        indent = "  " * depth
        prefix = "#{indent}#{i + 1}. "
        prefix_w = display_width(prefix)
        max_w = max_text_width(width, left, DEFAULT_SCALE) - prefix_w

        segments = Parser.parse_inline(item[:text])
        wrapped = wrap_segments(segments, max_w)

        wrapped.each_with_index do |line_segs, li|
          @terminal.move_to(row, left)
          if li == 0
            @terminal.write "#{KittyText.sized(prefix, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          else
            @terminal.write "#{KittyText.sized(" " * prefix_w, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          end
          row += DEFAULT_SCALE
        end
        row += 1
      end
      row
    end

    def render_definition_list(block, width, row)
      left = content_left(width)
      max_w = max_text_width(width, left, DEFAULT_SCALE)

      segments = Parser.parse_inline(block[:term])
      wrapped = wrap_segments(segments, max_w)
      wrapped.each do |line_segs|
        @terminal.move_to(row, left)
        @terminal.write "#{ANSI[:bold]}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}#{ANSI[:reset]}"
        row += DEFAULT_SCALE
      end

      def_max_w = [max_w - 4, 1].max
      block[:definition].each_line do |line|
        segments = Parser.parse_inline(line.chomp)
        wrapped = wrap_segments(segments, def_max_w)
        wrapped.each do |line_segs|
          @terminal.move_to(row, left + 4)
          @terminal.write render_segments_scaled(line_segs, DEFAULT_SCALE)
          row += DEFAULT_SCALE
        end
      end
      row
    end

    def render_blockquote(block, width, row)
      left = content_left(width)
      prefix = "| "
      prefix_w = display_width(prefix)
      max_w = max_text_width(width, left + 1, DEFAULT_SCALE) - prefix_w

      block[:content].each_line do |line|
        text = line.chomp
        segments = [[:text, text]]
        wrapped = wrap_segments(segments, max_w)

        wrapped.each_with_index do |line_segs, li|
          @terminal.move_to(row, left + 1)
          p = li == 0 ? prefix : " " * prefix_w
          @terminal.write "#{ANSI[:dim]}#{KittyText.sized(p, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}#{ANSI[:reset]}"
          row += DEFAULT_SCALE
        end
      end
      row
    end

    def render_table(block, width, row)
      left = content_left(width)
      all_rows = [block[:header]] + block[:rows]
      col_widths = Array.new(block[:header]&.size || 0, 0)
      all_rows.each do |cells|
        cells&.each_with_index do |cell, ci|
          col_widths[ci] = [col_widths[ci] || 0, display_width(cell)].max
        end
      end

      all_rows.each_with_index do |cells, ri|
        next unless cells

        @terminal.move_to(row, left)
        line = cells.each_with_index.map { |cell, ci|
          pad_to_width(cell, col_widths[ci] || 0)
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

    def render_image(block, width, row)
      path = resolve_image_path(block[:path])
      return row + DEFAULT_SCALE unless File.exist?(path)

      img_size = ImageUtil.image_size(path)
      return row + DEFAULT_SCALE unless img_size

      img_w, img_h = img_size
      cell_w, cell_h = @terminal.cell_pixel_size

      available_rows = @terminal.height - row - 2
      left = content_left(width)
      available_cols = width - left * 2

      if (rh = block[:attrs]['relative_height'])
        target_rows = (@terminal.height * rh.to_i / 100.0).to_i
        available_rows = [target_rows, available_rows].min
      end

      # Calculate target cell size maintaining aspect ratio
      img_cell_w = img_w.to_f / cell_w
      img_cell_h = img_h.to_f / cell_h
      scale = [available_cols / img_cell_w, available_rows / img_cell_h, 1.0].min
      target_cols = (img_cell_w * scale).to_i
      target_rows = (img_cell_h * scale).to_i
      target_cols = [target_cols, 1].max
      target_rows = [target_rows, 1].max

      x = [(width - target_cols) / 2, 0].max

      if ImageUtil.kitty_terminal?
        data = ImageUtil.kitty_icat(path, cols: target_cols, rows: target_rows, x: x, y: row - 1)
        @terminal.write data if data && !data.empty?
      elsif ImageUtil.sixel_available?
        @terminal.move_to(row, x + 1)
        target_pixel_w = target_cols * cell_w
        target_pixel_h = target_rows * cell_h
        sixel = ImageUtil.sixel_encode(path, width: target_pixel_w, height: target_pixel_h)
        @terminal.write sixel if sixel && !sixel.empty?
      end

      row + target_rows
    end

    def resolve_image_path(path)
      return path if File.absolute_path?(path) == path
      File.expand_path(path, @base_dir)
    end

    def content_left(width)
      width / 16
    end

    def max_text_width(terminal_width, left_col, scale)
      (terminal_width - left_col) / scale
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

    def render_segments_scaled(segments, para_scale)
      segments.map { |segment|
        type = segment[0]
        content = segment[1]
        case type
        when :tag
          tag_name = segment[2]
          if (scale = Parser::SIZE_SCALES[tag_name])
            KittyText.sized(content, s: scale)
          elsif Parser::NAMED_COLORS.key?(tag_name)
            "#{color_code(tag_name)}#{KittyText.sized(content, s: para_scale)}#{ANSI[:reset]}"
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

    def render_inline_scaled(text, para_scale)
      render_segments_scaled(Parser.parse_inline(text), para_scale)
    end

    # Wrap parsed inline segments into lines that fit within max_width display units
    def wrap_segments(segments, max_width)
      return [segments] if max_width <= 0

      lines = [[]]
      width = 0

      segments.each do |seg|
        content = seg[1] || ""
        seg_w = display_width(content)

        if width + seg_w <= max_width
          lines.last << seg
          width += seg_w
          next
        end

        remaining = content
        loop do
          space = max_width - width
          if space <= 0
            lines << []
            width = 0
            space = max_width
          end

          chunk, remaining = split_by_display_width(remaining, space)
          lines.last << [seg[0], chunk, *Array(seg[2..])]
          width += display_width(chunk)

          break unless remaining
          lines << []
          width = 0
        end
      end

      lines
    end

    def split_by_display_width(text, max_width)
      w = 0
      text.each_char.with_index do |c, i|
        cw = display_width(c)
        if w + cw > max_width && w > 0
          return [text[0...i], text[i..]]
        end
        w += cw
      end
      [text, nil]
    end

    def truncate_to_width(text, max_width)
      w = 0
      text.each_char.with_index do |c, i|
        cw = display_width(c)
        return text[0...i] if w + cw > max_width
        w += cw
      end
      text
    end

    def pad_to_width(text, target_width)
      current = display_width(text)
      text + " " * [target_width - current, 0].max
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

    def display_width(str)
      str.each_char.sum { |c|
        o = c.ord
        if o >= 0x1100 &&
            (o <= 0x115f ||
             o == 0x2329 || o == 0x232a ||
             (o >= 0x2e80 && o <= 0x303e) ||
             (o >= 0x3040 && o <= 0x33bf) ||
             (o >= 0x3400 && o <= 0x4dbf) ||
             (o >= 0x4e00 && o <= 0xa4cf) ||
             (o >= 0xac00 && o <= 0xd7a3) ||
             (o >= 0xf900 && o <= 0xfaff) ||
             (o >= 0xfe30 && o <= 0xfe6f) ||
             (o >= 0xff00 && o <= 0xff60) ||
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

    def calculate_height(blocks, width)
      blocks.sum { |b| block_height(b, width) }
    end

    def block_height(block, width)
      s = DEFAULT_SCALE
      left = content_left(width)
      max_w = max_text_width(width, left, s)

      case block[:type]
      when :heading
        scale = KittyText::HEADING_SCALES[block[:level]] || s
        if block[:level] == 1
          scale + 4
        else
          lines_count(block[:content], [max_w - 2, 1].max) * scale
        end
      when :paragraph
        para_scale = max_inline_scale(block[:content]) || s
        lines_count(block[:content], [max_text_width(width, left, para_scale), 1].max) * para_scale
      when :code_block
        [block[:content].lines.size * s, s].max
      when :unordered_list
        block[:items].sum { |item|
          prefix_w = (item[:depth] || 0) * 2 + 2
          lines_count(item[:text], [max_w - prefix_w, 1].max) * s
        }
      when :ordered_list
        block[:items].size * s
      when :definition_list
        term_lines = lines_count(block[:term], [max_w, 1].max)
        def_lines = block[:definition].lines.sum { |l| lines_count(l.chomp, [max_w - 4, 1].max) }
        (term_lines + def_lines) * s
      when :blockquote
        block[:content].lines.sum { |l| lines_count(l.chomp, [max_w - 3, 1].max) } * s
      when :table
        ((block[:header] ? 2 : 0) + block[:rows].size) * s
      when :image
        image_block_height(block, width)
      when :align
        0
      when :blank
        s
      else
        s
      end
    end

    def lines_count(text, max_width)
      vis_w = display_width(strip_markup(text))
      return 1 if vis_w <= max_width
      (vis_w.to_f / max_width).ceil
    end

    def image_block_height(block, width)
      path = resolve_image_path(block[:path])
      img_size = ImageUtil.image_size(path)
      return DEFAULT_SCALE unless img_size

      img_w, img_h = img_size
      cell_w, cell_h = @terminal.cell_pixel_size
      h = @terminal.height

      left = content_left(width)
      available_cols = width - left * 2
      available_rows = h / 2

      if (rh = block[:attrs]['relative_height'])
        available_rows = (h * rh.to_i / 100.0).to_i
      end

      img_cell_w = img_w.to_f / cell_w
      img_cell_h = img_h.to_f / cell_h
      scale = [available_cols / img_cell_w, available_rows / img_cell_h, 1.0].min
      [(img_cell_h * scale).ceil, 1].max
    end
  end
end
