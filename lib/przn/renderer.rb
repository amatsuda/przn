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
      @theme = theme || Theme.default
      @image_cache = {}
      @kitty_uploads = {}
      @mutex = Mutex.new
    end

    def render(slide, current:, total:)
      @mutex.synchronize do
        @terminal.clear
        apply_slide_background(slide)
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
    end

    # Warm caches for a slide we expect to navigate to soon. Uploads any PNG
    # images on the Kitty Graphics Protocol so the next render only needs a
    # placement command. Safe to call from a background thread; serialized
    # against `render` via the renderer's mutex so terminal writes don't
    # interleave.
    def preload(slide)
      return unless ImageUtil.kitty_terminal?

      @mutex.synchronize do
        slide.blocks.each do |block|
          next unless block[:type] == :image
          path = resolve_image_path(block[:path])
          next unless File.exist?(path) && ImageUtil.png?(path)
          ensure_kitty_uploaded(path)
        end
        @terminal.flush
      end
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
      when :bg              then row
      else row + 1
      end
    end

    # Emit Echoes' OSC 7772 to set a slide-specific solid color or gradient,
    # or clear any previous override. A `<bg .../>` block on the slide wins;
    # otherwise the theme's `bg:` section is used as the deck-wide default.
    # Other terminals ignore the OSC code, so this is a no-op outside Echoes.
    def apply_slide_background(slide)
      block = slide.blocks.find { |b| b[:type] == :bg }
      attrs = block ? block[:attrs] : (@theme.background || {})

      @terminal.write "\e]7772;bg-clear\a"
      return if attrs.empty?

      if (color = attrs[:color])
        @terminal.write "\e]7772;bg-color;#{color}\a"
        return
      end

      colors = [attrs[:from], attrs[:to]].compact
      return if colors.size < 2

      type = attrs[:type] || 'linear'
      angle = attrs[:angle] || 0
      @terminal.write "\e]7772;bg-gradient;type=#{type}:angle=#{angle}:colors=#{colors.join(',')}\a"
    end

    def render_heading(block, width, row)
      text = block[:content]

      if block[:level] == 1
        title = @theme.title || {}
        scale = (title[:size] && Parser::SIZE_SCALES[title[:size].to_s]) || KittyText::HEADING_SCALES[1]
        face = title[:family]
        color = title[:color]
        max_w = max_text_width(width, 0, scale)
        segments = Parser.parse_inline(text)
        wrapped = wrap_segments(segments, max_w, scale)

        wrapped.each do |line_segs|
          vis = segments_visible_cells(line_segs, scale)
          pad = [(width - vis) / 2, 0].max
          @terminal.move_to(row, pad + 1)
          @terminal.write "#{ANSI[:bold]}#{render_segments_scaled(line_segs, scale, default_face: face, default_h: 2, default_color: color)}#{ANSI[:reset]}"
          row += scale
        end
        row + 4
      else
        left = content_left(width)
        prefix = @theme.bullet[:text]
        prefix_w = display_width(prefix)
        max_w = max_text_width(width, left, DEFAULT_SCALE) - prefix_w
        segments = Parser.parse_inline(text)
        wrapped = wrap_segments(segments, max_w, DEFAULT_SCALE)

        wrapped.each_with_index do |line_segs, li|
          @terminal.move_to(row, left)
          if li == 0
            @terminal.write "#{render_bullet(prefix)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
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
      wrapped = wrap_segments(segments, max_w, scale)

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
        prefix = "#{indent}#{@theme.bullet[:text]}"
        prefix_w = display_width(prefix)
        max_w = max_text_width(width, left, DEFAULT_SCALE) - prefix_w

        segments = Parser.parse_inline(item[:text])
        wrapped = wrap_segments(segments, max_w, DEFAULT_SCALE)

        wrapped.each_with_index do |line_segs, li|
          @terminal.move_to(row, left)
          if li == 0
            @terminal.write "#{render_bullet(prefix)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
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
        wrapped = wrap_segments(segments, max_w, DEFAULT_SCALE)

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
      wrapped = wrap_segments(segments, max_w, DEFAULT_SCALE)
      wrapped.each do |line_segs|
        @terminal.move_to(row, left)
        @terminal.write "#{ANSI[:bold]}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}#{ANSI[:reset]}"
        row += DEFAULT_SCALE
      end

      def_max_w = [max_w - 4, 1].max
      block[:definition].each_line do |line|
        segments = Parser.parse_inline(line.chomp)
        wrapped = wrap_segments(segments, def_max_w, DEFAULT_SCALE)
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
        wrapped = wrap_segments(segments, max_w, DEFAULT_SCALE)

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

      if ImageUtil.kitty_terminal? && ImageUtil.png?(path)
        image_id = ensure_kitty_uploaded(path)
        @terminal.move_to(row, x + 1)
        @terminal.write ImageUtil.kitty_place(image_id: image_id, cols: target_cols, rows: target_rows)
      elsif ImageUtil.kitty_terminal?
        data = cached_kitty_icat(path, cols: target_cols, rows: target_rows, x: x, y: row - 1)
        @terminal.write data if data && !data.empty?
      elsif ImageUtil.sixel_available?
        @terminal.move_to(row, x + 1)
        target_pixel_w = target_cols * cell_w
        target_pixel_h = target_rows * cell_h
        sixel = cached_sixel_encode(path, width: target_pixel_w, height: target_pixel_h)
        @terminal.write sixel if sixel && !sixel.empty?
      end

      row + target_rows
    end

    def resolve_image_path(path)
      return path if File.absolute_path?(path) == path
      File.expand_path(path, @base_dir)
    end

    # Memoize the encoded escape-sequence bytes so revisiting a slide
    # skips both the subprocess fork and the image decode/encode work.
    # Keyed by file mtime so edits to the source image invalidate.
    def cached_kitty_icat(path, cols:, rows:, x:, y:)
      key = [:kitty, path, image_mtime(path), cols, rows, x, y]
      return @image_cache[key] if @image_cache.key?(key)
      @image_cache[key] = ImageUtil.kitty_icat(path, cols: cols, rows: rows, x: x, y: y)
    end

    def cached_sixel_encode(path, width:, height:)
      key = [:sixel, path, image_mtime(path), width, height]
      return @image_cache[key] if @image_cache.key?(key)
      @image_cache[key] = ImageUtil.sixel_encode(path, width: width, height: height)
    end

    def image_mtime(path)
      File.mtime(path).to_f
    rescue Errno::ENOENT
      nil
    end

    # Upload a PNG to the Kitty terminal once and return the assigned image
    # id. Subsequent renders of the same file (same mtime) reuse the id and
    # only emit a small placement command, skipping the file-transfer cost.
    def ensure_kitty_uploaded(path)
      key = [path, image_mtime(path)]
      return @kitty_uploads[key] if @kitty_uploads.key?(key)

      image_id = @kitty_uploads.size + 1
      @terminal.write ImageUtil.kitty_upload_png(path, image_id: image_id)
      @kitty_uploads[key] = image_id
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

    # Render the list/heading bullet. When `bullet_size` is smaller than the
    # body scale, use OSC 66 fractional scaling (n/d) with v=2 to keep the
    # glyph's cell footprint at body scale but draw a smaller dot vertically
    # centered. Plain `s=N` for a smaller bullet would top-align it inside
    # the row, which looks wrong against the larger body text.
    def render_bullet(prefix)
      size = @theme.bullet[:size]
      if size && size < DEFAULT_SCALE
        KittyText.sized(prefix, s: DEFAULT_SCALE, n: size, d: DEFAULT_SCALE, v: 2)
      else
        KittyText.sized(prefix, s: size || DEFAULT_SCALE)
      end
    end

    # Render a <font face="..." size="..." color="..."> run. The face goes out
    # via OSC 66 f= (Echoes extension); the size resolves through the same
    # SIZE_SCALES table that <size=N> uses; the color wraps in the same ANSI
    # escape that <color=NAME> uses.
    def render_font_segment(content, attrs, para_scale, default_face: nil, default_h: nil)
      scale = (attrs[:size] && Parser::SIZE_SCALES[attrs[:size]]) || para_scale
      base = KittyText.sized(content, s: scale, f: attrs[:face] || default_face, h: default_h)
      color = attrs[:color]
      return base unless color
      "#{color_code(color)}#{base}#{ANSI[:reset]}"
    end

    # `default_face:` / `default_color:` let a caller (currently h1 rendering)
    # override the OSC 66 `f=` and the ANSI fg for every emit on the line.
    # When unset, body text falls back to `theme.font.family` / `theme.font.color`.
    # To opt out of that body fallback (so a heading can render in the
    # terminal's defaults even when body text is themed), pass the keyword
    # explicitly — even `nil` is honored. Inline `<font face/color>` and
    # `<color=...>` runs still win for their own segments.
    #
    # `default_h:` threads an OSC 66 `h=` (horizontal alignment) into every
    # emit on the line. h1 uses h=2 so a proportional `title.family` is
    # centered within the reserved cell block — without it the glyphs left-
    # align inside the block and the visible text drifts left of the center
    # column we computed.
    def render_segments_scaled(segments, para_scale, default_face: :body, default_h: nil, default_color: :body)
      f = default_face == :body ? @theme.font[:family] : default_face
      h = default_h
      c = default_color == :body ? @theme.font[:color] : default_color
      body_open = c ? color_code(c) : ""
      inner = segments.map { |segment|
        type = segment[0]
        content = segment[1]
        case type
        when :tag
          tag_name = segment[2]
          if (scale = Parser::SIZE_SCALES[tag_name])
            KittyText.sized(content, s: scale, f: f, h: h)
          elsif Parser::NAMED_COLORS.key?(tag_name)
            "#{color_code(tag_name)}#{KittyText.sized(content, s: para_scale, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
          else
            KittyText.sized(content, s: para_scale, f: f, h: h)
          end
        when :font          then "#{render_font_segment(content, segment[2] || {}, para_scale, default_face: f, default_h: h)}#{(segment[2] || {})[:color] ? body_open : ''}"
        when :note          then "#{ANSI[:dim]}#{KittyText.sized(content, s: para_scale, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :bold          then "#{ANSI[:bold]}#{KittyText.sized(content, s: para_scale, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :italic        then "#{ANSI[:italic]}#{KittyText.sized(content, s: para_scale, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :strikethrough then "#{ANSI[:strikethrough]}#{KittyText.sized(content, s: para_scale, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :code          then "#{ANSI[:gray_bg]}#{KittyText.sized(" #{content} ", s: para_scale, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :text          then KittyText.sized(content, s: para_scale, f: f, h: h)
        end
      }.join
      body_open.empty? ? inner : "#{body_open}#{inner}#{ANSI[:reset]}"
    end

    def render_inline_scaled(text, para_scale)
      render_segments_scaled(Parser.parse_inline(text), para_scale)
    end

    # Wrap parsed inline segments into lines that fit within max_width units,
    # where 1 unit = `para_scale` terminal cells. Per-segment scaling (e.g.
    # size tags) is honored so a span with a larger scale consumes more budget.
    def wrap_segments(segments, max_width, para_scale = DEFAULT_SCALE)
      return [segments] if max_width <= 0

      max_cells = max_width * para_scale
      lines = [[]]
      used = 0

      segments.each do |seg|
        content = seg[1] || ""
        next if content.empty?

        seg_scale = effective_seg_scale(seg, para_scale)
        seg_cells = display_width(content) * seg_scale

        if used + seg_cells <= max_cells
          lines.last << seg
          used += seg_cells
          next
        end

        remaining = content
        loop do
          space_cells = max_cells - used
          if space_cells < seg_scale && used > 0
            lines << []
            used = 0
            space_cells = max_cells
          end

          chunk_max_dw = [space_cells / seg_scale, 1].max
          chunk, remaining = split_by_display_width(remaining, chunk_max_dw)
          lines.last << [seg[0], chunk, *Array(seg[2..])]
          used += display_width(chunk) * seg_scale

          break unless remaining
          lines << []
          used = 0
        end
      end

      lines
    end

    def effective_seg_scale(seg, para_scale)
      case seg[0]
      when :tag
        Parser::SIZE_SCALES[seg[2]] || para_scale
      when :font
        size = seg[2].is_a?(Hash) ? seg[2][:size] : nil
        (size && Parser::SIZE_SCALES[size]) || para_scale
      else
        para_scale
      end
    end

    def segments_visible_cells(segments, para_scale)
      segments.sum { |seg|
        content = seg[1] || ""
        display_width(content) * effective_seg_scale(seg, para_scale)
      }
    end

    # Split `text` so the first piece fits within `max_width` cells, preferring
    # to break at the last whitespace before the overflow rather than mid-word.
    # Falls back to a char-level split when no whitespace is available — single
    # long words, CJK runs (no inter-character whitespace) — so a word that's
    # itself longer than the line still wraps instead of overflowing.
    def split_by_display_width(text, max_width)
      w = 0
      last_space = nil
      text.each_char.with_index do |c, i|
        cw = display_width(c)
        if w + cw > max_width && w > 0
          if c == ' '
            return [text[0...i], text[(i + 1)..]]
          elsif last_space && last_space > 0
            return [text[0...last_space], text[(last_space + 1)..]]
          else
            return [text[0...i], text[i..]]
          end
        end
        w += cw
        last_space = i if c == ' '
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
             (o >= 0x1f300 && o <= 0x1faff) ||  # emoji blocks; terminals render these as 2 cells
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
        .gsub(/&(lt|gt|amp);/) { |_| {"lt" => "<", "gt" => ">", "amp" => "&"}[$1] }
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
      when :bg
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
