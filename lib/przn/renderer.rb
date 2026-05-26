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
      reset:         "\e[0m"
    }.freeze

    DEFAULT_SCALE = 2

    # Default `relative_height` (as a percent of terminal height) applied to
    # image blocks that don't carry an explicit one. Caps how much of the
    # screen a single image can occupy; the rest leaves predictable margin
    # for the slide footer and avoids placement-clearing edge cases in some
    # terminals when an image lands right against the bottom row.
    DEFAULT_IMAGE_RELATIVE_HEIGHT_PERCENT = 70

    # `mode:` controls whether `{::note}` / `<note>` segments are rendered:
    #   :solo      — dim-inline (today's behavior), default for stand-alone runs.
    #   :audience  — stripped from output; the projector view never shows notes.
    #   :presenter — dim-inline (so the presenter sees them in context) and
    #                ALSO aggregated separately for the side panel via
    #                Slide#notes; this renderer just keeps the inline copy.
    def initialize(terminal, base_dir: '.', theme: nil, mode: :solo)
      @terminal = terminal
      @base_dir = base_dir
      @theme = theme || Theme.default
      @mode = mode
      @image_cache = {}
      @kitty_uploads = {}
      @mutex = Mutex.new
      # Horizontal cell offset applied by `term_move` to flow-mode block
      # rendering. Set per slot inside `render_layout`; zero everywhere
      # else. Screen-absolute emits (footer, runner bar, render_at,
      # `<img x y>` absolute mode) bypass it and call @terminal.move_to
      # directly.
      @x_offset = 0
      # Per-slot text-style overrides (`size` / `family` / `color`)
      # populated by `render_layout` for the duration of one slot.
      # render_heading h1, render_paragraph, and the :body defaults in
      # render_segments_scaled consult this so a `cover.title` slot
      # with `size: xxx-large` actually makes the title bigger.
      @slot_style = nil
    end

    def render(slide, current:, total:, started_at: nil)
      @mutex.synchronize do
        @terminal.clear
        apply_slide_background(slide)
        w = @terminal.width
        h = @terminal.height

        # Resolve the slide's effective layout name:
        #   `# Title {layout=name}` on the slide wins.
        #   Otherwise: slide 0 prefers `cover` (if the theme ships one),
        #   every other slide falls through to `default`.
        #   `{layout=none}` is an explicit per-slide opt-out — useful
        #   when a custom default layout isn't right for one slide.
        layout_name = slide.layout
        layout_name ||= 'cover' if current == 0 && @theme.layouts['cover']
        layout_name ||= 'default'
        layout_name = nil if layout_name == 'none'
        layout = layout_name && @theme.layouts[layout_name]

        if layout
          render_layout(slide, layout, w, h)
        else
          # `{layout=none}` (or a theme stripped of `default`) — render
          # blocks top-down from row 2 with no slot routing.
          row = 2
          pending_align = nil
          slide.blocks.each do |block|
            if block[:type] == :align
              pending_align = block[:align]
            else
              row = render_block(block, w, row, align: pending_align)
              pending_align = nil
            end
          end
        end

        if @theme.rabbit
          draw_runner_bar(h, w, current, total, started_at)
        else
          status = " #{current + 1} / #{total} "
          @terminal.move_to(h, w - status.size)
          @terminal.write "#{ANSI[:dim]}#{status}#{ANSI[:reset]}"
        end

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

    # Move the terminal cursor in flow-mode block coordinates: `col` is
    # measured from the left of the current slot (or from the screen edge
    # when no slot is active, @x_offset = 0). Screen-absolute emits
    # (footer, runner bar, render_at, `<img x y>`) bypass this and call
    # @terminal.move_to directly so a layout context can't shift them.
    def term_move(row, col)
      @terminal.move_to(row, col + @x_offset)
    end

    # Resolve the current slot's `size:` override into an OSC 66 scale
    # (1-7). nil when no slot styling applies or the slot didn't set
    # a size — caller falls back to its own default (HEADING_SCALES,
    # DEFAULT_SCALE, etc.).
    def slot_scale
      return nil unless @slot_style
      name = @slot_style[:size]
      name && Parser::SIZE_SCALES[name]
    end

    # The active slot's `family:` override, or nil.
    def slot_family
      @slot_style && @slot_style[:family]
    end

    # The active slot's `color:` override, or nil.
    def slot_color
      @slot_style && @slot_style[:color]
    end

    # Group a slide's blocks into per-slot lists and render each slot in
    # its own region. The first slot named `title` (if any) is auto-filled
    # from the h1; remaining slots fill in declaration order, advanced by
    # a `<slot/>` block. `<slot name="...">` jumps to that slot if it
    # exists. Slots whose blocks would resolve to an invalid region (x/y
    # missing or unparseable) are skipped silently.
    def render_layout(slide, slots, width, height)
      buckets = route_blocks_to_slots(slide.blocks, slots)

      slots.each do |slot|
        blocks = buckets[slot.name] || []
        next if blocks.empty?
        x = resolve_at_coord(slot.x, width)
        y = resolve_at_coord(slot.y, height)
        w = resolve_at_coord(slot.width, width)
        next unless x && y && w

        prev_offset = @x_offset
        prev_style = @slot_style
        @x_offset = x - 1
        @slot_style = {size: slot.size, family: slot.family, color: slot.color}.compact
        @slot_style = nil if @slot_style.empty?
        begin
          row = y
          pending_align = nil
          blocks.each do |block|
            if block[:type] == :align
              pending_align = block[:align]
            else
              row = render_block(block, w, row, align: pending_align || slot.align)
              pending_align = nil
            end
          end
        ensure
          @x_offset = prev_offset
          @slot_style = prev_style
        end
      end
    end

    # Walk the slide's blocks once and bucket each one into a slot name.
    # The h1 (first heading at level 1) goes into the `title` slot when
    # one exists. Remaining blocks fill the first non-title slot until a
    # `:slot` block advances the cursor (`<slot/>` → next slot;
    # `<slot name="X"/>` → jump to slot X by name). Blocks past the last
    # slot are silently dropped — the slot list is the layout contract.
    def route_blocks_to_slots(blocks, slots)
      buckets = Hash.new { |h, k| h[k] = [] }
      title_slot = slots.find { |s| s.name == 'title' }
      non_title_slots = title_slot ? slots.reject { |s| s.equal?(title_slot) } : slots
      cursor = 0  # index into non_title_slots

      blocks.each do |block|
        if title_slot && block[:type] == :heading && block[:level] == 1 && !buckets.key?('title')
          buckets['title'] << block
        elsif block[:type] == :slot
          if block[:name]
            idx = non_title_slots.index { |s| s.name == block[:name] }
            cursor = idx if idx
          else
            cursor += 1
          end
        else
          next if cursor >= non_title_slots.size
          buckets[non_title_slots[cursor].name] << block
        end
      end
      buckets
    end

    def render_block(block, width, row, align: nil)
      case block[:type]
      when :heading         then render_heading(block, width, row, align: align)
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
      when :slot            then row
      when :at              then render_at(block); row
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

    # Place text at an absolute (column, row) on the slide, escaping the
    # normal top-down paragraph flow. Coordinates are 1-based terminal cells
    # to match the CSI cursor-position escape. A trailing `%` interprets the
    # value as a percentage of the terminal's width (for `x=`) or height
    # (for `y=`) — `x="50%" y="50%"` lands at the middle of the pane,
    # auto-resizing with the terminal. Content is parsed inline so
    # `<size>`, `<color>`, `<font>`, **bold**, etc. all work inside `<at>`.
    # The block contributes 0 to the slide's layout height so it doesn't
    # push subsequent content down.
    def render_at(block)
      attrs = block[:attrs] || {}
      x = resolve_at_coord(attrs[:x], @terminal.width)
      y = resolve_at_coord(attrs[:y], @terminal.height)
      return if x.nil? || y.nil?

      segments = Parser.parse_inline(block[:content].to_s)
      @terminal.move_to(y, x)
      @terminal.write render_segments_scaled(segments, DEFAULT_SCALE)
    end

    # Resolve an `<at>` coordinate string against the dimension it indexes.
    # `"50%"` → halfway along `max`; plain integer string → that number of
    # cells. Out-of-range values clamp into [1, max]. Returns nil when the
    # input is missing or unparseable so the renderer skips silently.
    def resolve_at_coord(raw, max)
      return nil if raw.nil?

      s = raw.to_s.strip
      return nil if s.empty?

      cells =
        if s.end_with?('%')
          pct = s.chomp('%').to_f
          (pct / 100.0 * max).round
        elsif s =~ /\A-?\d+\z/
          s.to_i
        end
      return nil if cells.nil?

      cells.clamp(1, max)
    end

    # Bottom-row progress indicator (Rabbit-style):
    #
    #   1                   🐢                🐇                   9
    #   └ current slide #   └ elapsed time    └ slide progress     └ goal (total slides)
    #
    # The anchor numbers (current at the left, total at the right) sit on the
    # very bottom row; the emojis render at OSC 66 scale 2 and are anchored at
    # row `h-1` so their bottom half lands on row `h` next to the numbers,
    # making them visibly twice as large as the labels without needing more
    # vertical screen real-estate. The turtle is hidden when
    # `theme.rabbit.duration` is unset / unparseable. `flip=h` mirrors each
    # glyph horizontally on terminals that honor it (Echoes); others ignore
    # the parameter and the emojis face left.
    EMOJI_RUNNER_CELLS = 4 # 🐇/🐢 are 2 source cells wide, rendered at s=2 → 4 cells

    def draw_runner_bar(h, w, current, total, started_at)
      left  = (current + 1).to_s
      right = total.to_s
      track_left  = left.size + 2          # 1 cell gap after the left number
      track_right = w - right.size - 1     # 1 cell gap before the right number
      return if track_right - track_left < EMOJI_RUNNER_CELLS

      @terminal.move_to(h, 1)
      @terminal.write "#{ANSI[:dim]}#{left}#{ANSI[:reset]}"
      @terminal.move_to(h, w - right.size + 1)
      @terminal.write "#{ANSI[:dim]}#{right}#{ANSI[:reset]}"

      rabbit_row = [h - 1, 1].max
      rabbit_col = runner_col(current, [total - 1, 1].max, track_left, track_right)
      @terminal.move_to(rabbit_row, rabbit_col)
      @terminal.write KittyText.sized('🐇', s: 2, flip: 'h')

      duration_s = Theme.parse_duration(@theme.rabbit[:duration])
      return unless started_at && duration_s && duration_s.positive?

      elapsed = Time.now - started_at
      frac = (elapsed / duration_s).clamp(0.0, 1.0)
      span = (track_right - (EMOJI_RUNNER_CELLS - 1)) - track_left
      turtle_col = track_left + (frac * [span, 0].max).round
      @terminal.move_to(rabbit_row, turtle_col)
      @terminal.write KittyText.sized('🐢', s: 2, flip: 'h')
    end

    # Linear-interpolate a runner's column inside the track. `step` is 0..max
    # (e.g. current slide index 0..total-1), and the returned column leaves
    # enough room for an emoji `EMOJI_RUNNER_CELLS` cells wide before the
    # right-anchor number.
    def runner_col(step, max, track_left, track_right)
      return track_left if max <= 0
      span = (track_right - (EMOJI_RUNNER_CELLS - 1)) - track_left
      span = 0 if span < 0
      track_left + (step.to_f / max * span).round
    end

    def render_heading(block, width, row, align: nil)
      text = block[:content]

      if block[:level] == 1
        title = @theme.title || {}
        scale = slot_scale || (title[:size] && Parser::SIZE_SCALES[title[:size].to_s]) || KittyText::HEADING_SCALES[1]
        face = slot_family || title[:family]
        color = slot_color || title[:color]
        max_w = max_text_width(width, 0, scale)
        segments = Parser.parse_inline(text)
        wrapped = wrap_segments(segments, max_w, scale)

        wrapped.each do |line_segs|
          vis = segments_visible_cells(line_segs, scale)
          pad = compute_pad(width, vis, align)
          term_move(row, pad + 1)
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
          term_move(row, left)
          if li == 0
            @terminal.write "#{render_bullet(prefix)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          else
            @terminal.write "#{KittyText.sized(' ' * prefix_w, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          end
          row += DEFAULT_SCALE
        end
        row
      end
    end

    def render_paragraph(block, width, row, align: nil)
      text = block[:content]
      scale = max_inline_scale(text) || slot_scale || DEFAULT_SCALE
      left = content_left(width)

      if align
        vis = visible_width_scaled(text, scale)
        left = compute_pad(width, vis, align)
      end

      max_w = max_text_width(width, left, scale)
      segments = Parser.parse_inline(text)
      wrapped = wrap_segments(segments, max_w, scale)

      wrapped.each do |line_segs|
        term_move(row, left + 1)
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
        term_move(row, left + 1)
        @terminal.write "#{ANSI[:gray_bg]}#{KittyText.sized("  #{padded}  ", s: DEFAULT_SCALE)}#{ANSI[:reset]}"
        row += DEFAULT_SCALE
      end

      row
    end

    def render_unordered_list(block, width, row)
      left = content_left(width)
      block[:items].each do |item|
        depth = item[:depth] || 0
        indent = '  ' * depth
        prefix = "#{indent}#{@theme.bullet[:text]}"
        prefix_w = display_width(prefix)
        max_w = max_text_width(width, left, DEFAULT_SCALE) - prefix_w

        segments = Parser.parse_inline(item[:text])
        wrapped = wrap_segments(segments, max_w, DEFAULT_SCALE)

        wrapped.each_with_index do |line_segs, li|
          term_move(row, left)
          if li == 0
            @terminal.write "#{render_bullet(prefix)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          else
            @terminal.write "#{KittyText.sized(' ' * prefix_w, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
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
        indent = '  ' * depth
        prefix = "#{indent}#{i + 1}. "
        prefix_w = display_width(prefix)
        max_w = max_text_width(width, left, DEFAULT_SCALE) - prefix_w

        segments = Parser.parse_inline(item[:text])
        wrapped = wrap_segments(segments, max_w, DEFAULT_SCALE)

        wrapped.each_with_index do |line_segs, li|
          term_move(row, left)
          if li == 0
            @terminal.write "#{KittyText.sized(prefix, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
          else
            @terminal.write "#{KittyText.sized(' ' * prefix_w, s: DEFAULT_SCALE)}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}"
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
        term_move(row, left)
        @terminal.write "#{ANSI[:bold]}#{render_segments_scaled(line_segs, DEFAULT_SCALE)}#{ANSI[:reset]}"
        row += DEFAULT_SCALE
      end

      def_max_w = [max_w - 4, 1].max
      block[:definition].each_line do |line|
        segments = Parser.parse_inline(line.chomp)
        wrapped = wrap_segments(segments, def_max_w, DEFAULT_SCALE)
        wrapped.each do |line_segs|
          term_move(row, left + 4)
          @terminal.write render_segments_scaled(line_segs, DEFAULT_SCALE)
          row += DEFAULT_SCALE
        end
      end
      row
    end

    def render_blockquote(block, width, row)
      left = content_left(width)
      prefix = '| '
      prefix_w = display_width(prefix)
      max_w = max_text_width(width, left + 1, DEFAULT_SCALE) - prefix_w

      block[:content].each_line do |line|
        text = line.chomp
        segments = [[:text, text]]
        wrapped = wrap_segments(segments, max_w, DEFAULT_SCALE)

        wrapped.each_with_index do |line_segs, li|
          term_move(row, left + 1)
          p = li == 0 ? prefix : ' ' * prefix_w
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

        term_move(row, left)
        line = cells.each_with_index.map { |cell, ci|
          pad_to_width(cell, col_widths[ci] || 0)
        }.join('  |  ')
        if ri == 0
          @terminal.write "#{ANSI[:bold]}#{KittyText.sized(line, s: DEFAULT_SCALE)}#{ANSI[:reset]}"
        else
          @terminal.write KittyText.sized(line, s: DEFAULT_SCALE)
        end
        row += DEFAULT_SCALE

        if ri == 0
          term_move(row, left)
          @terminal.write KittyText.sized(col_widths.map { |w| '-' * w }.join('--+--'), s: DEFAULT_SCALE)
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

      attrs = block[:attrs] || {}
      abs_x = resolve_at_coord(attrs['x'], @terminal.width)
      abs_y = resolve_at_coord(attrs['y'], @terminal.height)
      absolute = abs_x && abs_y

      origin_row = absolute ? abs_y : row
      available_rows = [@terminal.height - origin_row - 2, 1].max
      if absolute
        available_cols = [@terminal.width - abs_x + 1, 1].max
      else
        left = content_left(width)
        available_cols = width - left * 2
      end

      # Cap the default vertical area to 70 % of the screen, matching what
      # `{:relative_height="70"}` would do explicitly. Large images that
      # extend to within a couple of rows of the screen edge render
      # unreliably in some terminals — they're known-good at 70 %, and
      # smaller images sit well within this cap so they're unaffected.
      # An explicit `relative_height` still overrides.
      default_rh = DEFAULT_IMAGE_RELATIVE_HEIGHT_PERCENT
      rh = attrs['relative_height'] || default_rh
      target_rows = (@terminal.height * rh.to_i / 100.0).to_i
      available_rows = [target_rows, available_rows].min

      # Calculate target cell size maintaining aspect ratio
      img_cell_w = img_w.to_f / cell_w
      img_cell_h = img_h.to_f / cell_h
      scale = [available_cols / img_cell_w, available_rows / img_cell_h, 1.0].min
      target_cols = (img_cell_w * scale).to_i
      target_rows = (img_cell_h * scale).to_i
      target_cols = [target_cols, 1].max
      target_rows = [target_rows, 1].max

      if absolute
        y_cell, x_cell = abs_y, abs_x
      else
        y_cell = row
        # In flow mode, fold the active slot offset into x_cell so both
        # move_to and the kitty_icat coordinate land in the right column.
        # Absolute mode (`<img x y>`) already names the screen cell.
        x_cell = [(width - target_cols) / 2, 0].max + 1 + @x_offset
      end

      if ImageUtil.kitty_terminal? && ImageUtil.png?(path)
        image_id = ensure_kitty_uploaded(path)
        @terminal.move_to(y_cell, x_cell)
        @terminal.write ImageUtil.kitty_place(image_id: image_id, cols: target_cols, rows: target_rows)
      elsif ImageUtil.kitty_terminal?
        data = cached_kitty_icat(path, cols: target_cols, rows: target_rows, x: x_cell - 1, y: y_cell - 1)
        @terminal.write data if data && !data.empty?
      elsif ImageUtil.sixel_available?
        @terminal.move_to(y_cell, x_cell)
        target_pixel_w = target_cols * cell_w
        target_pixel_h = target_rows * cell_h
        sixel = cached_sixel_encode(path, width: target_pixel_w, height: target_pixel_h)
        @terminal.write sixel if sixel && !sixel.empty?
      end

      absolute ? row : row + target_rows
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
      f = default_face == :body ? (slot_family || @theme.font[:family]) : default_face
      h = default_h
      c = default_color == :body ? (slot_color || @theme.font[:color]) : default_color
      body_open = c ? color_code(c) : ''
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
        when :note          then @mode == :audience ? "" : "#{ANSI[:dim]}#{KittyText.sized(content, s: para_scale, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
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
        content = seg[1] || ''
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
        content = seg[1] || ''
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
      text + ' ' * [target_width - current, 0].max
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
        ''
      end
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

  end
end
