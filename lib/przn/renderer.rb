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


    # `mode:` controls whether `{::note}` / `<note>` segments are rendered:
    #   :solo      — dim-inline (today's behavior), default for stand-alone runs.
    #   :audience  — stripped from output; the projector view never shows notes.
    #   :presenter — dim-inline (so the presenter sees them in context) and
    #                ALSO aggregated separately for the side panel via
    #                Slide#notes; this renderer just keeps the inline copy.
    # `export_mode:` true when the renderer is driving a PDF export (currently
    # ScreenshotPdfExporter): suppresses the 🐇/🐢 runner bar in favor of the
    # plain `N / M` counter, since the emoji animation belongs on a live screen,
    # not a static page.
    # Swap in a fresh theme without rebuilding the renderer (so the
    # image / kitty-upload caches survive). Used by the `r` reload
    # path so a theme.yml edit takes effect mid-session.
    attr_accessor :theme
    attr_reader :export_mode

    def initialize(terminal, base_dir: '.', theme: nil, mode: :solo, export_mode: false)
      @terminal = terminal
      @base_dir = base_dir
      @theme = theme || Theme.default
      @mode = mode
      @export_mode = export_mode
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
      # Kitty image id of the previous slide's background image (when
      # set via `<bg image="..."/>` or `background.image:` in theme).
      # Tracked so the placement can be deleted before the next slide
      # applies its own bg — keeps the upload cached but wipes the
      # visible artifact.
      @bg_image_id = nil
    end

    def render(slide, current:, total:, started_at: nil, step: 0)
      @mutex.synchronize do
        # Per-block visibility for incremental reveals. Each `<wait/>`
        # block bumps the step counter, so block_step[b] = "step at
        # which block b becomes visible." A block is rendered iff
        # block_step[b] <= step; otherwise its flow space is *reserved*
        # but no bytes reach the terminal. See `suppressed_render`.
        @block_step = compute_block_step(slide.blocks)
        @current_step = step
        # Action overrides accumulated up to the current step. Keyed
        # by target id; merged into a block's attrs at render time.
        # See `compute_effective_state` and `effective_attrs`.
        @effective_state = compute_effective_state(slide.blocks, @block_step, step)
        @terminal.clear
        # Wipe the previous slide's `<img>` / shape placements (cached
        # image data stays alive). The current slide re-emits its own
        # placements below; the alternative — letting placements leak
        # — would mean every prior slide's images bleed through onto
        # later ones, since kitty placements aren't tied to the cell
        # buffer that @terminal.clear empties.
        @terminal.write ImageUtil.kitty_delete_all_placements if ImageUtil.kitty_terminal?
        apply_slide_background(slide)
        w = @terminal.width
        h = @terminal.height

        # Pre-pass: register shape placements AND fully-positioned `<img>`
        # placements (both x and y set) BEFORE any text writes. Echoes'
        # kitty graphics implementation erases the cells covered by a
        # placement when the placement is registered, then text writes
        # to those cells later restore the cell buffer (via
        # erase_multicell_at). The placement itself stays in the GUI's
        # @placements list and re-blits on top — so where the SVG / PNG
        # is transparent, the underlying text shows through. Solid
        # fills and opaque PNGs still occlude (Echoes has no z-index
        # yet); thin strokes and outlined shapes coexist with text
        # cleanly. Without this pass, text rendered BEFORE a positioned
        # image was clobbered by the placement's cell-buffer wipe and
        # disappeared even where the image had no opaque pixels.
        #
        # Hidden positioned content (block_step > current_step) is
        # skipped outright — absolute placements don't take flow space
        # so there's nothing to reserve, and we don't want a hidden
        # image's bytes on the terminal before its reveal step.
        slide.blocks.each do |block|
          next if hidden?(block)
          case block[:type]
          when :shape
            render_shape(block)
          when :image
            attrs = effective_attrs(block)
            # Only "both-axes" positioned images can be pre-placed —
            # x-only / y-only images still need the flow `row` to
            # decide the unpinned axis, so they stay in the
            # layout/flow pass below.
            next unless attrs['x'] && attrs['y']
            render_image(block, w, 1)
          end
        end

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
            case block[:type]
            when :align  then pending_align = block[:align]
            when :wait   then next
            when :action then next  # mutation already applied via @effective_state
            else
              row = render_block_or_reserve(block, w, row, align: pending_align)
              pending_align = nil
            end
          end
        end

        if counter_duration && !@export_mode
          draw_runner_bar(h, w, current, total, started_at)
        else
          status = " #{current + 1} / #{total} "
          @terminal.move_to(h, w - status.size)
          @terminal.write "#{counter_color_open}#{status}#{ANSI[:reset]}"
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
      # Code-block tokenizer warmup. Pays the `require 'rouge'` and
      # per-lexer autoload costs *here*, on the background preload
      # thread, so the first user-visible render of a slide with
      # fenced code doesn't sit waiting for Rouge to load. Pure CPU
      # work into a thread-safe in-process cache — no terminal I/O —
      # so it deliberately runs outside the renderer mutex (no point
      # blocking a foreground render on tokenization).
      slide.blocks.each do |block|
        next unless block[:type] == :code_block && block[:language]
        CodeHighlighter.highlight(block[:content], block[:language])
      end

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

    # Public entrypoint for the controller's runner-bar refresh thread.
    # Recomputes just the bottom-row 🐇/🐢 / N-M counter — leaves the
    # rest of the slide untouched. No-op when the theme didn't opt
    # into the runner bar (no `counter.duration`) or we're in export
    # mode. Serialized against full slide renders via the renderer's
    # mutex so the background thread can't tear writes.
    def redraw_runner_bar(current:, total:, started_at:)
      return if @export_mode
      return unless counter_duration
      @mutex.synchronize do
        draw_runner_bar(@terminal.height, @terminal.width, current, total, started_at)
        @terminal.flush
      end
    end

    # How many discrete steps a slide has — one per `<wait/>` block,
    # plus one for the initial state with nothing revealed. The
    # controller uses this to decide whether Space advances within
    # the slide or flips to the next one.
    def step_count(slide)
      slide.blocks.count { |b| b[:type] == :wait } + 1
    end

    private

    # Tiny stand-in for @terminal that swallows writes. Used by
    # `suppressed_render` so a hidden block's render path still runs
    # end-to-end (returning the same row advancement it would have
    # produced visibly), but no bytes reach the real terminal.
    # Mirrors the @terminal interface the renderer touches (see
    # `grep -o '@terminal\.\w*' lib/przn/renderer.rb`).
    class NullTerm
      def initialize(real)
        @width = real.width
        @height = real.height
        @cell_px = real.respond_to?(:cell_pixel_size) ? real.cell_pixel_size : [10, 20]
      end
      def width;  @width;  end
      def height; @height; end
      def cell_pixel_size; @cell_px; end
      def write(_); end
      def move_to(_, _); end
      def clear; end
      def flush; end
    end

    # Walk slide.blocks once and assign each block the step at which
    # it becomes visible (= the count of `:wait` blocks preceding it).
    # Returns a Hash keyed by the block dict itself (object identity)
    # because the same dicts flow through route_blocks_to_slots into
    # the layout pass and through the no-layout pass — both pick them
    # back up by reference.
    def compute_block_step(blocks)
      step = 0
      map = {}
      blocks.each do |block|
        map[block] = step
        step += 1 if block[:type] == :wait
      end
      map
    end

    # Build the "effective state" map for the current step: walk every
    # `:action` block in slide order, and for each one that's already
    # been triggered (block_step[a] <= current_step), accumulate its
    # attr overrides under `state[target_id]`. Later actions targeting
    # the same id overwrite earlier ones, so the final state is "the
    # latest action that fired against each target."
    #
    # Returns `{target_id => {key => value, ...}}` where keys are the
    # action's raw attr names (string `id` if from `<img>`-style attrs,
    # symbol `:x` if from `<at>`-style — `effective_attrs` reconciles
    # against the target block's own key style at merge time).
    def compute_effective_state(blocks, block_step, current_step)
      state = {}
      blocks.each do |block|
        next unless block[:type] == :action
        next if (block_step[block] || 0) > current_step
        attrs = block[:attrs] || {}
        target = attrs[:target] || attrs['target']
        next unless target
        bucket = (state[target] ||= {})
        attrs.each do |k, v|
          key = k.to_s
          next if key == 'target'
          bucket[key] = v
        end
      end
      state
    end

    # Merge a block's stored attrs with any action-driven overrides
    # for that block's id. The block's original key style (string vs
    # symbol) is preserved so the downstream render path keeps
    # reading attrs the same way it always has — only the values
    # change.
    def effective_attrs(block)
      attrs = block[:attrs] || {}
      return attrs unless @effective_state
      id = attrs['id'] || attrs[:id]
      override = id && @effective_state[id]
      return attrs unless override

      result = attrs.dup
      override.each do |k, v|
        if attrs.key?(k.to_sym)
          result[k.to_sym] = v
        else
          result[k.to_s] = v
        end
      end
      result
    end

    # True when this block hasn't been revealed yet at the current
    # step. Pre-pass uses this to skip hidden positioned content
    # outright; the flow pass uses it to switch to `suppressed_render`.
    def hidden?(block)
      ((@block_step && @block_step[block]) || 0) > (@current_step || 0)
    end

    # Visibility-aware wrapper around `render_block`. Visible blocks
    # render normally; hidden ones go through `suppressed_render`,
    # which advances the row the same amount but writes nothing —
    # so layout stays stable as the user advances steps, instead of
    # everything reflowing up each time a new block reveals.
    def render_block_or_reserve(block, width, row, align: nil)
      if hidden?(block)
        suppressed_render(block, width, row, align: align)
      else
        render_block(block, width, row, align: align)
      end
    end

    # Run the full render_block path with @terminal swapped to a
    # NullTerm. The block's natural row advancement is preserved
    # (every height-aware render function computes its own row math
    # and returns the new row), so reserving layout space happens
    # automatically without duplicating per-block-type measurements.
    def suppressed_render(block, width, row, align: nil)
      real = @terminal
      @terminal = NullTerm.new(real)
      begin
        render_block(block, width, row, align: align)
      ensure
        @terminal = real
      end
    end

    # Move the terminal cursor in flow-mode block coordinates: `col` is
    # measured from the left of the current slot (or from the screen edge
    # when no slot is active, @x_offset = 0). Screen-absolute emits
    # (footer, runner bar, render_at, `<img x y>`) bypass this and call
    # @terminal.move_to directly so a layout context can't shift them.
    def term_move(row, col)
      @terminal.move_to(row, col + @x_offset)
    end

    # Body-text OSC 66 scale (1-7). Reads `theme.font.size` and resolves
    # via Parser::SIZE_SCALES (so `xx-small` / `2` / `large` all map to
    # the same table title.size uses), falling back to DEFAULT_SCALE
    # when unset. Consulted everywhere body text is rendered or
    # vertically advanced — paragraphs, list items, blockquotes,
    # code blocks, definition lists, table rows, blank rows, h2–h6.
    def body_scale
      size = @theme.font && @theme.font[:size]
      (size && Parser::SIZE_SCALES[size.to_s]) || DEFAULT_SCALE
    end

    # Parsed `theme.counter.duration` in seconds, or nil when unset /
    # unparseable. Truthy here is what opts the bottom row into the
    # 🐇 / 🐢 runner bar; nil falls back to the plain " N / M " counter.
    def counter_duration
      raw = @theme.counter && @theme.counter[:duration]
      raw && Theme.parse_duration(raw)
    end

    # Open-SGR for the bottom-row counter (plain `N / M` and the
    # runner-bar anchor numbers). Honors `theme.counter.color`
    # (named ANSI or 6-digit hex); falls back to the dim ANSI default.
    def counter_color_open
      c = @theme.counter && @theme.counter[:color]
      (c && !c.to_s.empty?) ? color_code(c.to_s) : ANSI[:dim]
    end

    # Resolve the current slot's `size:` override into an OSC 66 scale
    # (1-7). nil when no slot styling applies or the slot didn't set
    # a size — caller falls back to its own default (HEADING_SCALES,
    # body_scale, etc.).
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

      cell_w, cell_h = @terminal.cell_pixel_size
      slots.each do |slot|
        blocks = buckets[slot.name] || []
        next if blocks.empty?
        x = resolve_at_coord(slot.x, width, cell_px: cell_w)
        y = resolve_at_coord(slot.y, height, cell_px: cell_h)
        w = resolve_at_coord(slot.width, width, cell_px: cell_w)
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
            case block[:type]
            when :align  then pending_align = block[:align]
            when :wait   then next
            when :action then next  # mutation already applied via @effective_state
            else
              row = render_block_or_reserve(block, w, row, align: pending_align || slot.align)
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
      when :image           then render_image_or_skip(block, width, row)
      when :shape           then row   # rendered in render()'s pre-pass
      when :blank           then row + body_scale
      when :bg              then row
      when :slot            then row
      when :wait            then row   # step boundary marker, not a renderable
      when :action          then row   # state mutation, applied via effective_attrs
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
      clear_background_image
      return if attrs.empty?

      # An `image:` background wins over color / gradient — the image
      # covers the whole slide area at z: -1 so subsequent text and
      # `<img>` placements draw on top.
      if (image = attrs[:image])
        apply_background_image(image.to_s)
        return
      end

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

    # Cover the slide with a Kitty Graphics image at z: -1 so text
    # drawn afterward layers on top. PNG only for now (relies on the
    # in-process upload path; JPGs would need a kitten icat detour).
    # Silently no-ops on non-Kitty terminals — the bg-clear emitted
    # above already wiped any prior Echoes color / gradient.
    def apply_background_image(path)
      return unless ImageUtil.kitty_terminal?
      resolved = resolve_image_path(path)
      return unless File.exist?(resolved) && ImageUtil.png?(resolved)

      image_id = ensure_kitty_uploaded(resolved)
      @bg_image_id = image_id
      @terminal.move_to(1, 1)
      @terminal.write ImageUtil.kitty_place(
        image_id: image_id,
        cols: @terminal.width,
        rows: @terminal.height,
        z: -1
      )
    end

    # Delete the previous slide's bg-image placement (if any) so it
    # doesn't bleed through to a slide that defines no image bg.
    # Image data stays cached so revisiting the same bg doesn't
    # re-upload.
    def clear_background_image
      return unless @bg_image_id && ImageUtil.kitty_terminal?
      @terminal.write ImageUtil.kitty_delete_placements(image_id: @bg_image_id)
      @bg_image_id = nil
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
      attrs = effective_attrs(block)
      cell_w, cell_h = @terminal.cell_pixel_size
      x = resolve_at_coord(attrs[:x], @terminal.width, cell_px: cell_w)
      y = resolve_at_coord(attrs[:y], @terminal.height, cell_px: cell_h)
      return if x.nil? || y.nil?

      segments = Parser.parse_inline(block[:content].to_s)
      # Split on `:break` (from <br>) and emit each chunk on its own
      # row at the same x. `render_segments_scaled` itself doesn't
      # know about :break — it's a styling renderer, not a wrapping
      # one — so we handle the line break here.
      lines = [[]]
      segments.each do |seg|
        seg[0] == :break ? (lines << []) : (lines.last << seg)
      end
      # Advance y by each line's *own* height (the max inline scale
      # of its segments). When the whole `<at>` is wrapped in
      # `<font size=1>` or `<size=1>`, the lines pack tight at
      # 1 cell apart; a `<size=5>` line takes 5 cells before the
      # next line starts. Falls back to body_scale when a line
      # carries no explicit size, matching the pre-fix behavior.
      y_cursor = y
      lines.each do |line_segs|
        line_h = max_segment_scale(line_segs, body_scale)
        @terminal.move_to(y_cursor, x)
        @terminal.write render_segments_scaled(line_segs, body_scale, line_height: line_h)
        y_cursor += line_h
      end
    end

    # Compute a single line's vertical extent in terminal cells. Each
    # segment contributes either its explicit `<size=...>` / `<font
    # size="...">` scale, or `default_scale` when it has no size of
    # its own; the line's height is the max across all of them.
    #
    # Crucially this can return *less* than `default_scale` — a line
    # entirely wrapped in `<font size=1>` returns 1, so `<br>`-stacked
    # small text packs tight at 1 cell per line instead of body_scale
    # cells. Plain text mixed with a small-sized tag still uses
    # body_scale (the plain part needs the room).
    def max_segment_scale(segments, default_scale)
      return default_scale if segments.empty?
      segments.map { |seg|
        type = seg[0]
        size_key =
          case type
          when :tag  then seg[2]
          when :font then (seg[2] || {})[:size]
          end
        Parser::SIZE_SCALES[size_key] || default_scale
      }.max
    end

    # Draw a Keynote-style shape primitive (rect, circle, ellipse, line,
    # polyline, polygon) by composing a tiny self-contained SVG document
    # and shipping it via the Kitty Graphics Protocol's direct-data mode.
    # Echoes content-sniffs the payload and rasterizes it through its
    # native CoreGraphics fast path (sub-millisecond for path-only SVGs,
    # which these always are).
    #
    # Geometry is authored in slide-cell coords (or `N%` of the terminal
    # w/h) but composed into the SVG in **pixel** coords. The SVG
    # viewBox matches the cell-quantized rasterization target exactly,
    # which keeps 1 user unit = 1 pixel and avoids the anisotropic
    # stretch that would otherwise turn `<circle>` into an ellipse
    # (terminal cells are ~1:2 wide-to-tall). For "axis-agnostic"
    # extents (`r`, `stroke-width`) we use `cell_w` as the canonical
    # unit so a `circle r="5"` renders as a true circle.
    # Shapes are absolute-positioned and contribute 0 to the layout flow.
    def render_shape(block)
      return unless ImageUtil.kitty_terminal?
      kind = block[:kind]
      attrs = effective_attrs(block)
      cell_w, cell_h = @terminal.cell_pixel_size
      return unless cell_w&.positive? && cell_h&.positive?

      geom = resolve_shape_geometry(kind, attrs, cell_w, cell_h)
      return unless geom

      sw_user = if attrs['stroke-width']
                  attrs['stroke-width'].to_f
                elsif open_shape?(kind)
                  SHAPE_DEFAULT_STROKE_WIDTH
                else
                  0.0
                end
      sw_px = sw_user * cell_w
      pad = sw_px / 2.0

      # Arrows need an arrowhead computed from the resolved stroke width
      # (the head dimensions scale with stroke). expand_arrow_geometry
      # adds the triangle vertices to `geom` and grows the bbox to fit.
      geom = expand_arrow_geometry(geom, sw_px) if kind == :arrow

      gx_min = geom[:bbox_x] - pad
      gy_min = geom[:bbox_y] - pad
      gx_max = geom[:bbox_x] + geom[:bbox_w] + pad
      gy_max = geom[:bbox_y] + geom[:bbox_h] + pad

      # Quantize the pixel bbox to whole slide cells.
      place_col0 = (gx_min / cell_w).floor       # 0-indexed cell col
      place_row0 = (gy_min / cell_h).floor
      end_col0   = (gx_max / cell_w).ceil
      end_row0   = (gy_max / cell_h).ceil
      cols = end_col0 - place_col0
      rows = end_row0 - place_row0
      return if cols < 1 || rows < 1

      # viewBox in pixels covers the cell-quantized footprint exactly.
      vb_x = place_col0 * cell_w
      vb_y = place_row0 * cell_h
      vb_w = cols * cell_w
      vb_h = rows * cell_h

      svg = build_shape_svg(kind, attrs, geom, sw_px, vb_x, vb_y, vb_w, vb_h)
      image_id = ensure_kitty_inline_uploaded(svg)
      @terminal.move_to(place_row0 + 1, place_col0 + 1)
      # z=-1 draws the shape below text but above the slide background,
      # so heading text / paragraphs at the same cells remain legible.
      # An explicit `z="..."` attr lets authors put a shape on top.
      z = attrs['z'] ? attrs['z'].to_i : -1
      @terminal.write ImageUtil.kitty_place(image_id: image_id, cols: cols, rows: rows, z: z)
    end

    # SVG paint / presentation attributes passed through to the shape
    # element verbatim. Anything else on `block[:attrs]` is treated as
    # geometry (consumed per-shape) and not re-emitted.
    SHAPE_PAINT_ATTRS = %w[
      fill stroke stroke-width opacity fill-opacity stroke-opacity
      stroke-linecap stroke-linejoin stroke-dasharray stroke-miterlimit
      fill-rule transform
    ].freeze

    SHAPE_DEFAULT_STROKE_WIDTH = 0.2

    OPEN_SHAPES = %i[line polyline arrow path].freeze

    def open_shape?(kind)
      OPEN_SHAPES.include?(kind)
    end

    # Resolve a shape's geometry attrs to pixel coordinates. Positional
    # attrs (x, y, cx, cy, x1, y1, x2, y2, polyline/polygon points) are
    # 1-indexed cell coords matching `<at>` semantics — cell N maps to
    # pixel `(N-1) * cell_dim`. Size attrs (width, height, rx, ry) are
    # cell counts → `N * cell_dim` pixels. `r` and other "axis-agnostic"
    # extents use `cell_w` as the canonical unit so a `circle r="5"`
    # renders visually circular regardless of cell aspect ratio.
    # Returns a hash with the per-shape geometry in pixels plus a
    # `:bbox_*` quadruple covering the shape's pixel extent, or nil if
    # any required attr is missing / unparseable.
    def resolve_shape_geometry(kind, attrs, cell_w, cell_h)
      case kind
      when :rect
        x  = to_px(attrs['x'],      :position, :x, cell_w, cell_h)
        y  = to_px(attrs['y'],      :position, :y, cell_w, cell_h)
        w_ = to_px(attrs['width'],  :size,     :x, cell_w, cell_h)
        h_ = to_px(attrs['height'], :size,     :y, cell_w, cell_h)
        return nil unless x && y && w_ && h_
        {bbox_x: x, bbox_y: y, bbox_w: w_, bbox_h: h_, x: x, y: y, w: w_, h: h_,
         rx: to_px(attrs['rx'], :size, :x, cell_w, cell_h),
         ry: to_px(attrs['ry'], :size, :y, cell_w, cell_h)}
      when :circle
        cx = to_px(attrs['cx'], :position, :x, cell_w, cell_h)
        cy = to_px(attrs['cy'], :position, :y, cell_w, cell_h)
        # r is axis-agnostic: use cell_w on both axes so the rasterized
        # shape is a true circle, not a vertical ellipse.
        r  = to_px(attrs['r'],  :size,     :x, cell_w, cell_h)
        return nil unless cx && cy && r
        {bbox_x: cx - r, bbox_y: cy - r, bbox_w: 2 * r, bbox_h: 2 * r, cx: cx, cy: cy, r: r}
      when :ellipse
        cx = to_px(attrs['cx'], :position, :x, cell_w, cell_h)
        cy = to_px(attrs['cy'], :position, :y, cell_w, cell_h)
        rx = to_px(attrs['rx'], :size,     :x, cell_w, cell_h)
        ry = to_px(attrs['ry'], :size,     :y, cell_w, cell_h)
        return nil unless cx && cy && rx && ry
        {bbox_x: cx - rx, bbox_y: cy - ry, bbox_w: 2 * rx, bbox_h: 2 * ry, cx: cx, cy: cy, rx: rx, ry: ry}
      when :line, :arrow
        # `<arrow>` shares the line's geometry surface; the renderer
        # adds a filled triangular head at (x2, y2) once stroke_width
        # is resolved (see expand_arrow_geometry).
        x1 = to_px(attrs['x1'], :position, :x, cell_w, cell_h)
        y1 = to_px(attrs['y1'], :position, :y, cell_w, cell_h)
        x2 = to_px(attrs['x2'], :position, :x, cell_w, cell_h)
        y2 = to_px(attrs['y2'], :position, :y, cell_w, cell_h)
        return nil unless x1 && y1 && x2 && y2
        {bbox_x: [x1, x2].min, bbox_y: [y1, y2].min,
         bbox_w: (x2 - x1).abs, bbox_h: (y2 - y1).abs,
         x1: x1, y1: y1, x2: x2, y2: y2}
      when :polyline, :polygon
        pts = parse_shape_points(attrs['points'], cell_w, cell_h)
        return nil if pts.nil? || pts.empty?
        xs = pts.map(&:first)
        ys = pts.map(&:last)
        {bbox_x: xs.min, bbox_y: ys.min,
         bbox_w: xs.max - xs.min, bbox_h: ys.max - ys.min,
         points: pts}
      when :path
        # Parse `d`, compute bbox in pixels, and rewrite the path data
        # from cell-space (what the user wrote) into pixel-space (what
        # the SVG viewBox expects). Rewriting avoids wrapping in a
        # `<g transform="scale(...)">` — a non-uniform scale would
        # render strokes elliptically, which is not what anyone wants.
        path_to_pixels(attrs['d'], cell_w, cell_h)
      end
    end

    # Convert a single coord attribute to pixels.
    #   role:  :position — 1-indexed cell N → pixel (N-1)*cell_dim
    #          :size     — cell count N → pixel N*cell_dim
    #   axis:  :x → cell_w & terminal.width;  :y → cell_h & terminal.height
    # `%` is allowed and resolves against the corresponding terminal
    # extent before the cell→pixel conversion.
    def to_px(raw, role, axis, cell_w, cell_h)
      return nil if raw.nil?
      s = raw.to_s.strip
      return nil if s.empty?

      cell_dim    = (axis == :x) ? cell_w : cell_h
      total_cells = (axis == :x) ? @terminal.width : @terminal.height

      cells =
        if s.end_with?('%')
          s.chomp('%').to_f / 100.0 * total_cells
        elsif s =~ /\A-?[\d.]+\z/
          s.to_f
        end
      return nil if cells.nil?

      role == :position ? (cells - 1) * cell_dim : cells * cell_dim
    end

    # Parse a `points="x1,y1 x2,y2 …"` attribute into resolved [x, y]
    # pixel-coord pairs. Coords are 1-indexed cells or `N%`; each
    # x uses `:x` axis, each y uses `:y` axis. Returns nil if the token
    # count is odd or any individual coord fails to parse.
    def parse_shape_points(raw, cell_w, cell_h)
      return nil if raw.nil?
      tokens = raw.to_s.split(/[\s,]+/).reject(&:empty?)
      return nil if tokens.empty? || tokens.size.odd?
      pts = []
      tokens.each_slice(2) do |xs, ys|
        x = to_px(xs, :position, :x, cell_w, cell_h)
        y = to_px(ys, :position, :y, cell_w, cell_h)
        return nil if x.nil? || y.nil?
        pts << [x, y]
      end
      pts
    end

    # Tokenizer / rewriter for SVG `<path d="...">` data. Returns
    # `{bbox_x:, bbox_y:, bbox_w:, bbox_h:, d:}` (all in pixel space)
    # or nil if the path data has an unknown command.
    #
    # User authors path data in 1-indexed slide cells, matching every
    # other shape coord (`<line x1>`, `<rect x>`, polyline points …).
    # We walk each command, accumulate every endpoint and control
    # point as a pixel coord (over-estimates the bbox slightly for
    # cubic / quadratic curves — control points commonly sit outside
    # the visible curve — but that's safe), and re-emit `d` with the
    # numbers translated. Absolute positions take the `(N-1)*cell_dim`
    # offset; relative deltas use the unshifted `N*cell_dim`. Arc `A`
    # / `a` rx & ry scale anisotropically (rx by cell_w, ry by
    # cell_h) so an author who wants a circular arc has to use equal
    # rx/ry written in cell-widths of *each* axis — same as the
    # `<circle>` vs `<ellipse>` distinction.
    PATH_TOKEN_RE = /[A-Za-z]|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/
    def path_to_pixels(d_attr, cell_w, cell_h)
      return nil if d_attr.nil?
      tokens = d_attr.to_s.scan(PATH_TOKEN_RE)
      return nil if tokens.empty?

      xs = []
      ys = []
      cx = 0.0
      cy = 0.0
      sx = 0.0   # subpath start (for Z)
      sy = 0.0
      out = []
      cmd = nil
      i = 0

      pos_x = ->(x) { (x - 1) * cell_w }
      pos_y = ->(y) { (y - 1) * cell_h }
      del_x = ->(x) { x * cell_w }
      del_y = ->(y) { y * cell_h }

      while i < tokens.size
        tok = tokens[i]
        if tok.match?(/\A[A-Za-z]\z/)
          cmd = tok
          out << cmd
          i += 1
          if cmd == 'Z' || cmd == 'z'
            cx, cy = sx, sy
          end
          next
        end

        case cmd
        when 'M', 'L', 'T'
          x = tokens[i].to_f; y = tokens[i + 1].to_f
          cx, cy = x, y
          sx, sy = cx, cy if cmd == 'M'
          px = pos_x.call(cx); py = pos_y.call(cy)
          xs << px; ys << py
          out << "#{fnum(px)} #{fnum(py)}"
          i += 2
          cmd = 'L' if cmd == 'M'
        when 'm', 'l', 't'
          dx = tokens[i].to_f; dy = tokens[i + 1].to_f
          cx += dx; cy += dy
          sx, sy = cx, cy if cmd == 'm'
          xs << pos_x.call(cx); ys << pos_y.call(cy)
          out << "#{fnum(del_x.call(dx))} #{fnum(del_y.call(dy))}"
          i += 2
          cmd = 'l' if cmd == 'm'
        when 'H'
          x = tokens[i].to_f
          cx = x
          xs << pos_x.call(cx); ys << pos_y.call(cy)
          out << fnum(pos_x.call(cx))
          i += 1
        when 'h'
          dx = tokens[i].to_f
          cx += dx
          xs << pos_x.call(cx); ys << pos_y.call(cy)
          out << fnum(del_x.call(dx))
          i += 1
        when 'V'
          y = tokens[i].to_f
          cy = y
          xs << pos_x.call(cx); ys << pos_y.call(cy)
          out << fnum(pos_y.call(cy))
          i += 1
        when 'v'
          dy = tokens[i].to_f
          cy += dy
          xs << pos_x.call(cx); ys << pos_y.call(cy)
          out << fnum(del_y.call(dy))
          i += 1
        when 'C'
          nums = (0..5).map { |k| tokens[i + k].to_f }
          # Three (x, y) pairs: two control points then endpoint.
          pairs = nums.each_slice(2).to_a
          pairs.each { |x, y| xs << pos_x.call(x); ys << pos_y.call(y) }
          cx, cy = pairs.last
          out << pairs.map { |x, y| "#{fnum(pos_x.call(x))} #{fnum(pos_y.call(y))}" }.join(' ')
          i += 6
        when 'c'
          nums = (0..5).map { |k| tokens[i + k].to_f }
          pairs_rel = nums.each_slice(2).to_a
          pairs_abs = pairs_rel.map { |dx, dy| [cx + dx, cy + dy] }
          pairs_abs.each { |x, y| xs << pos_x.call(x); ys << pos_y.call(y) }
          cx, cy = pairs_abs.last
          out << pairs_rel.map { |dx, dy| "#{fnum(del_x.call(dx))} #{fnum(del_y.call(dy))}" }.join(' ')
          i += 6
        when 'S', 'Q'
          nums = (0..3).map { |k| tokens[i + k].to_f }
          pairs = nums.each_slice(2).to_a
          pairs.each { |x, y| xs << pos_x.call(x); ys << pos_y.call(y) }
          cx, cy = pairs.last
          out << pairs.map { |x, y| "#{fnum(pos_x.call(x))} #{fnum(pos_y.call(y))}" }.join(' ')
          i += 4
        when 's', 'q'
          nums = (0..3).map { |k| tokens[i + k].to_f }
          pairs_rel = nums.each_slice(2).to_a
          pairs_abs = pairs_rel.map { |dx, dy| [cx + dx, cy + dy] }
          pairs_abs.each { |x, y| xs << pos_x.call(x); ys << pos_y.call(y) }
          cx, cy = pairs_abs.last
          out << pairs_rel.map { |dx, dy| "#{fnum(del_x.call(dx))} #{fnum(del_y.call(dy))}" }.join(' ')
          i += 4
        when 'A'
          rx = tokens[i].to_f; ry = tokens[i + 1].to_f
          rot = tokens[i + 2].to_f
          la  = tokens[i + 3].to_i
          sw_flag = tokens[i + 4].to_i
          x = tokens[i + 5].to_f; y = tokens[i + 6].to_f
          cx, cy = x, y
          xs << pos_x.call(cx); ys << pos_y.call(cy)
          out << "#{fnum(del_x.call(rx))} #{fnum(del_y.call(ry))} #{fnum(rot)} #{la} #{sw_flag} #{fnum(pos_x.call(x))} #{fnum(pos_y.call(y))}"
          i += 7
        when 'a'
          rx = tokens[i].to_f; ry = tokens[i + 1].to_f
          rot = tokens[i + 2].to_f
          la  = tokens[i + 3].to_i
          sw_flag = tokens[i + 4].to_i
          dx = tokens[i + 5].to_f; dy = tokens[i + 6].to_f
          cx += dx; cy += dy
          xs << pos_x.call(cx); ys << pos_y.call(cy)
          out << "#{fnum(del_x.call(rx))} #{fnum(del_y.call(ry))} #{fnum(rot)} #{la} #{sw_flag} #{fnum(del_x.call(dx))} #{fnum(del_y.call(dy))}"
          i += 7
        else
          return nil
        end
      end

      return nil if xs.empty?
      {bbox_x: xs.min, bbox_y: ys.min,
       bbox_w: xs.max - xs.min, bbox_h: ys.max - ys.min,
       d: out.join(' ')}
    end

    # Compose the SVG document shipped to the terminal. The viewBox is
    # in pixels and matches the cell-quantized rasterization footprint
    # exactly, so 1 user unit = 1 pixel — no anisotropic stretching,
    # circles render circular, stroke widths reproduce the exact pixel
    # thickness we computed. Default paint colors are spelled out as
    # `white` (not `currentColor`) so the SVG renders correctly even
    # if Echoes doesn't propagate the root `color=` to children.
    def build_shape_svg(kind, attrs, geom, sw_px, vb_x, vb_y, vb_w, vb_h)
      vb = "#{fnum(vb_x)} #{fnum(vb_y)} #{fnum(vb_w)} #{fnum(vb_h)}"
      shape_xml = shape_element(kind, attrs, geom, sw_px)
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{vb}">#{shape_xml}</svg>)
    end

    def shape_element(kind, attrs, geom, sw_px)
      paint = shape_paint_attrs(kind, attrs, sw_px)
      case kind
      when :rect
        rx = geom[:rx] ? %( rx="#{fnum(geom[:rx])}") : ''
        ry = geom[:ry] ? %( ry="#{fnum(geom[:ry])}") : ''
        %(<rect x="#{fnum(geom[:x])}" y="#{fnum(geom[:y])}" width="#{fnum(geom[:w])}" height="#{fnum(geom[:h])}"#{rx}#{ry}#{paint}/>)
      when :circle
        %(<circle cx="#{fnum(geom[:cx])}" cy="#{fnum(geom[:cy])}" r="#{fnum(geom[:r])}"#{paint}/>)
      when :ellipse
        %(<ellipse cx="#{fnum(geom[:cx])}" cy="#{fnum(geom[:cy])}" rx="#{fnum(geom[:rx])}" ry="#{fnum(geom[:ry])}"#{paint}/>)
      when :line
        %(<line x1="#{fnum(geom[:x1])}" y1="#{fnum(geom[:y1])}" x2="#{fnum(geom[:x2])}" y2="#{fnum(geom[:y2])}"#{paint}/>)
      when :arrow
        # Stem (line) + filled triangular head. The head's fill
        # defaults to the stem's stroke color so the two read as one
        # arrow; an explicit `fill="..."` on the tag overrides only
        # the head, giving a two-tone arrow if that's what you want.
        stem = %(<line x1="#{fnum(geom[:x1])}" y1="#{fnum(geom[:y1])}" x2="#{fnum(geom[:x2])}" y2="#{fnum(geom[:y2])}"#{paint}/>)
        tip, b1, b2 = geom[:head]
        head_pts = "#{fnum(tip[0])},#{fnum(tip[1])} #{fnum(b1[0])},#{fnum(b1[1])} #{fnum(b2[0])},#{fnum(b2[1])}"
        head_fill = normalize_svg_color(attrs['fill'] || attrs['stroke'] || 'white')
        stem + %(<polygon points="#{head_pts}" fill="#{head_fill}"/>)
      when :polyline
        %(<polyline points="#{points_attr(geom[:points])}"#{paint}/>)
      when :polygon
        %(<polygon points="#{points_attr(geom[:points])}"#{paint}/>)
      when :path
        # `d` has already been rewritten into pixel space by
        # path_to_pixels — stash on the geom hash so the renderer
        # never needs to know about cell coordinates here.
        %(<path d="#{geom[:d]}"#{paint}/>)
      end
    end

    # Compute the arrowhead triangle for an `<arrow>` shape and merge
    # the result back into the geom hash. Head dimensions scale with
    # stroke width: length 4× sw_px, width 3× sw_px — typical SVG
    # marker proportions. Bbox grows to include the head's vertices
    # so cell quantization reserves room for the triangle.
    def expand_arrow_geometry(geom, sw_px)
      x1 = geom[:x1].to_f
      y1 = geom[:y1].to_f
      x2 = geom[:x2].to_f
      y2 = geom[:y2].to_f
      dx = x2 - x1
      dy = y2 - y1
      len = Math.sqrt(dx * dx + dy * dy)
      return geom if len < 1e-6

      head_len = sw_px * 4.0
      head_wid = sw_px * 3.0
      ux = dx / len
      uy = dy / len
      base_cx = x2 - ux * head_len
      base_cy = y2 - uy * head_len
      # Perpendicular unit vector (rotate (ux,uy) by 90°).
      perp_x = -uy * head_wid / 2.0
      perp_y =  ux * head_wid / 2.0
      tip = [x2, y2]
      b1  = [base_cx + perp_x, base_cy + perp_y]
      b2  = [base_cx - perp_x, base_cy - perp_y]

      xs = [x1, x2, b1[0], b2[0]]
      ys = [y1, y2, b1[1], b2[1]]
      geom.merge(
        bbox_x: xs.min,
        bbox_y: ys.min,
        bbox_w: xs.max - xs.min,
        bbox_h: ys.max - ys.min,
        head: [tip, b1, b2]
      )
    end

    # `stroke-width` is overridden with the renderer-computed pixel
    # value so the user's "0.3" cell-widths becomes the actual pixel
    # count we padded the bbox by. The user's other paint attrs pass
    # through; sensible defaults fill in fill/stroke if unset. `fill`
    # and `stroke` get normalized through CSS_NAMED_COLORS so that
    # SVG names Echoes' fast path doesn't know natively (tomato,
    # gold, lavender, …) become `#rrggbb` before the SVG is shipped.
    def shape_paint_attrs(kind, attrs, sw_px)
      defaults =
        if open_shape?(kind)
          {'fill' => 'none', 'stroke' => 'white'}
        else
          {'fill' => 'white'}
        end
      out = defaults.merge(attrs.slice(*SHAPE_PAINT_ATTRS))
      out['fill']   = normalize_svg_color(out['fill'])   if out['fill']
      out['stroke'] = normalize_svg_color(out['stroke']) if out['stroke']
      # Replace stroke-width (if present, or implicit on open shapes)
      # with the pixel value matching our bbox padding.
      if out['stroke'] && out['stroke'] != 'none' && sw_px > 0
        out['stroke-width'] = fnum(sw_px)
      else
        out.delete('stroke-width')
      end
      out.map { |k, v| %( #{k}="#{v}") }.join
    end

    # Translate a named CSS color to `#rrggbb` so Echoes' SVG renderer
    # gets a hex code it always parses (its native named-color list
    # covers only ~22 of the 140 standard CSS names). Hex codes,
    # `rgb(...)` / `rgba(...)` functions, `none`, `currentColor`, and
    # `transparent` pass through unchanged; unknown names also pass
    # through (let Echoes decide).
    def normalize_svg_color(value)
      s = value.to_s
      return s if s.empty?
      return s if s.start_with?('#')
      return s if s.match?(/\A(?:rgb|rgba|hsl|hsla)\(/i)
      down = s.downcase
      return s if down == 'none' || down == 'currentcolor' || down == 'transparent'
      hex = CSS_NAMED_COLORS[down]
      hex ? "##{hex}" : s
    end

    # Full set of CSS / SVG named colors — the same 147-color table the
    # browsers ship. We translate every name to `#rrggbb` before handing
    # the SVG to Echoes so the deck author can write `fill="tomato"`,
    # `stroke="lavender"`, etc. without thinking about which subset the
    # terminal's named-color parser happens to recognize.
    CSS_NAMED_COLORS = {
      'aliceblue' => 'f0f8ff', 'antiquewhite' => 'faebd7', 'aqua' => '00ffff',
      'aquamarine' => '7fffd4', 'azure' => 'f0ffff', 'beige' => 'f5f5dc',
      'bisque' => 'ffe4c4', 'black' => '000000', 'blanchedalmond' => 'ffebcd',
      'blue' => '0000ff', 'blueviolet' => '8a2be2', 'brown' => 'a52a2a',
      'burlywood' => 'deb887', 'cadetblue' => '5f9ea0', 'chartreuse' => '7fff00',
      'chocolate' => 'd2691e', 'coral' => 'ff7f50', 'cornflowerblue' => '6495ed',
      'cornsilk' => 'fff8dc', 'crimson' => 'dc143c', 'cyan' => '00ffff',
      'darkblue' => '00008b', 'darkcyan' => '008b8b', 'darkgoldenrod' => 'b8860b',
      'darkgray' => 'a9a9a9', 'darkgrey' => 'a9a9a9', 'darkgreen' => '006400',
      'darkkhaki' => 'bdb76b', 'darkmagenta' => '8b008b', 'darkolivegreen' => '556b2f',
      'darkorange' => 'ff8c00', 'darkorchid' => '9932cc', 'darkred' => '8b0000',
      'darksalmon' => 'e9967a', 'darkseagreen' => '8fbc8f', 'darkslateblue' => '483d8b',
      'darkslategray' => '2f4f4f', 'darkslategrey' => '2f4f4f', 'darkturquoise' => '00ced1',
      'darkviolet' => '9400d3', 'deeppink' => 'ff1493', 'deepskyblue' => '00bfff',
      'dimgray' => '696969', 'dimgrey' => '696969', 'dodgerblue' => '1e90ff',
      'firebrick' => 'b22222', 'floralwhite' => 'fffaf0', 'forestgreen' => '228b22',
      'fuchsia' => 'ff00ff', 'gainsboro' => 'dcdcdc', 'ghostwhite' => 'f8f8ff',
      'gold' => 'ffd700', 'goldenrod' => 'daa520', 'gray' => '808080',
      'grey' => '808080', 'green' => '008000', 'greenyellow' => 'adff2f',
      'honeydew' => 'f0fff0', 'hotpink' => 'ff69b4', 'indianred' => 'cd5c5c',
      'indigo' => '4b0082', 'ivory' => 'fffff0', 'khaki' => 'f0e68c',
      'lavender' => 'e6e6fa', 'lavenderblush' => 'fff0f5', 'lawngreen' => '7cfc00',
      'lemonchiffon' => 'fffacd', 'lightblue' => 'add8e6', 'lightcoral' => 'f08080',
      'lightcyan' => 'e0ffff', 'lightgoldenrodyellow' => 'fafad2', 'lightgray' => 'd3d3d3',
      'lightgrey' => 'd3d3d3', 'lightgreen' => '90ee90', 'lightpink' => 'ffb6c1',
      'lightsalmon' => 'ffa07a', 'lightseagreen' => '20b2aa', 'lightskyblue' => '87cefa',
      'lightslategray' => '778899', 'lightslategrey' => '778899', 'lightsteelblue' => 'b0c4de',
      'lightyellow' => 'ffffe0', 'lime' => '00ff00', 'limegreen' => '32cd32',
      'linen' => 'faf0e6', 'magenta' => 'ff00ff', 'maroon' => '800000',
      'mediumaquamarine' => '66cdaa', 'mediumblue' => '0000cd', 'mediumorchid' => 'ba55d3',
      'mediumpurple' => '9370db', 'mediumseagreen' => '3cb371', 'mediumslateblue' => '7b68ee',
      'mediumspringgreen' => '00fa9a', 'mediumturquoise' => '48d1cc', 'mediumvioletred' => 'c71585',
      'midnightblue' => '191970', 'mintcream' => 'f5fffa', 'mistyrose' => 'ffe4e1',
      'moccasin' => 'ffe4b5', 'navajowhite' => 'ffdead', 'navy' => '000080',
      'oldlace' => 'fdf5e6', 'olive' => '808000', 'olivedrab' => '6b8e23',
      'orange' => 'ffa500', 'orangered' => 'ff4500', 'orchid' => 'da70d6',
      'palegoldenrod' => 'eee8aa', 'palegreen' => '98fb98', 'paleturquoise' => 'afeeee',
      'palevioletred' => 'db7093', 'papayawhip' => 'ffefd5', 'peachpuff' => 'ffdab9',
      'peru' => 'cd853f', 'pink' => 'ffc0cb', 'plum' => 'dda0dd',
      'powderblue' => 'b0e0e6', 'purple' => '800080', 'rebeccapurple' => '663399',
      'red' => 'ff0000', 'rosybrown' => 'bc8f8f', 'royalblue' => '4169e1',
      'saddlebrown' => '8b4513', 'salmon' => 'fa8072', 'sandybrown' => 'f4a460',
      'seagreen' => '2e8b57', 'seashell' => 'fff5ee', 'sienna' => 'a0522d',
      'silver' => 'c0c0c0', 'skyblue' => '87ceeb', 'slateblue' => '6a5acd',
      'slategray' => '708090', 'slategrey' => '708090', 'snow' => 'fffafa',
      'springgreen' => '00ff7f', 'steelblue' => '4682b4', 'tan' => 'd2b48c',
      'teal' => '008080', 'thistle' => 'd8bfd8', 'tomato' => 'ff6347',
      'turquoise' => '40e0d0', 'violet' => 'ee82ee', 'wheat' => 'f5deb3',
      'white' => 'ffffff', 'whitesmoke' => 'f5f5f5', 'yellow' => 'ffff00',
      'yellowgreen' => '9acd32'
    }.freeze

    def points_attr(points)
      points.map { |x, y| "#{fnum(x)},#{fnum(y)}" }.join(' ')
    end

    # Compact float formatting for SVG: drop trailing ".0" on integral
    # values, otherwise emit up to three decimals. Keeps the payload
    # short and the cache key stable.
    def fnum(n)
      f = n.to_f
      i = f.to_i
      f == i ? i.to_s : format('%.3f', f)
    end

    # Resolve a coordinate string against the dimension it indexes.
    # Accepts four suffix forms; the bare-number case picks between cells
    # and pixels based on `default_unit:` so each tag can pick the unit
    # that matches its native vocabulary (`<at>` → cells, `<img>` → px).
    #
    #   "50%"  → halfway along `max` cells
    #   "100px"→ 100 pixels (anchor cell + sub-cell pixel offset)
    #   "10c"  → cell 10 (1-based; explicit)
    #   "10"   → cell 10 OR 10 px (per default_unit)
    #
    # Pixel forms compute both the *anchor cell* (the 1-based cell
    # containing that pixel) and the pixel remainder *within* that cell
    # — useful for Kitty Graphics' `X=`/`Y=` sub-cell offsets, which
    # give true 1-px positioning instead of snap-to-cell.
    #
    # By default this returns just the anchor cell (preserving the old
    # `<at>`/`<slot>` shape). Pass `with_offset: true` to get back
    # `[cell, px_offset_within_anchor]` instead — `<img>` uses the pair
    # form because images can place at any sub-cell pixel; text and
    # slots stay cell-snapped because they have to.
    #
    # `cell_px` is required for any px form; if it's nil and a px-form
    # value is given, returns nil. Out-of-range values clamp into
    # [1, max] and the sub-cell offset is zeroed if the clamp moved the
    # cell (the placement is going off-screen anyway, no point keeping
    # a stale offset). Returns nil when the input is missing or
    # unparseable so the renderer skips silently.
    def resolve_at_coord(raw, max, cell_px: nil, default_unit: :cell, with_offset: false)
      return nil if raw.nil?

      s = raw.to_s.strip
      return nil if s.empty?

      cell = nil
      px_off = 0

      if s.end_with?('%')
        pct = s.chomp('%').to_f
        cell = (pct / 100.0 * max).round
      elsif (m = s.match(/\A(-?\d+(?:\.\d+)?)px\z/))
        return nil unless cell_px && cell_px > 0
        px = m[1].to_f
        cell = (px / cell_px).floor + 1
        px_off = (px - (cell - 1) * cell_px).to_i
      elsif (m = s.match(/\A(-?\d+)c\z/))
        cell = m[1].to_i
      elsif s =~ /\A-?\d+(?:\.\d+)?\z/
        if default_unit == :px
          return nil unless cell_px && cell_px > 0
          px = s.to_f
          cell = (px / cell_px).floor + 1
          px_off = (px - (cell - 1) * cell_px).to_i
        else
          cell = s.to_i
        end
      end
      return nil if cell.nil?

      clamped = cell.clamp(1, max)
      px_off = 0 if clamped != cell
      cell = clamped

      with_offset ? [cell, px_off] : cell
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
    # vertical screen real-estate. `flip=h` mirrors each glyph horizontally
    # on terminals that honor it (Echoes); others ignore the parameter and
    # the emojis face left.
    EMOJI_RUNNER_CELLS = 4 # 🐇/🐢 are 2 source cells wide, rendered at s=2 → 4 cells

    def draw_runner_bar(h, w, current, total, started_at)
      left  = (current + 1).to_s
      right = total.to_s
      track_left  = left.size + 2          # 1 cell gap after the left number
      track_right = w - right.size - 1     # 1 cell gap before the right number
      return if track_right - track_left < EMOJI_RUNNER_CELLS

      rabbit_row = [h - 1, 1].max

      # Wipe the emoji track before redrawing so a previous turtle
      # position (left over from the last runner-bar thread tick)
      # doesn't ghost beside the new one. Row h has the anchor
      # numbers — they're re-written right below so they don't need
      # a wipe.
      @terminal.move_to(rabbit_row, track_left)
      @terminal.write ' ' * (track_right - track_left + EMOJI_RUNNER_CELLS)

      open_seq = counter_color_open
      @terminal.move_to(h, 1)
      @terminal.write "#{open_seq}#{left}#{ANSI[:reset]}"
      @terminal.move_to(h, w - right.size + 1)
      @terminal.write "#{open_seq}#{right}#{ANSI[:reset]}"

      rabbit_col = runner_col(current, [total - 1, 1].max, track_left, track_right)
      @terminal.move_to(rabbit_row, rabbit_col)
      @terminal.write KittyText.sized('🐇', s: 2, flip: 'h')

      duration_s = counter_duration
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
        max_w = max_text_width(width, left, body_scale) - prefix_w
        segments = Parser.parse_inline(text)
        wrapped = wrap_segments(segments, max_w, body_scale)

        wrapped.each_with_index do |line_segs, li|
          term_move(row, left)
          if li == 0
            @terminal.write "#{render_bullet(prefix)}#{render_segments_scaled(line_segs, body_scale)}"
          else
            @terminal.write "#{KittyText.sized(' ' * prefix_w, s: body_scale)}#{render_segments_scaled(line_segs, body_scale)}"
          end
          row += body_scale
        end
        row
      end
    end

    def render_paragraph(block, width, row, align: nil)
      text = block[:content]
      # Two scales, not one:
      #   - `base_scale` is the cell size for plain (unsized) text.
      #     Always body_scale (or the active slot's override) — a
      #     `<font size=xx-large>` somewhere in the paragraph must
      #     NOT pull body text up with it.
      #   - row advance happens per line and uses each line's own
      #     `max_segment_scale` so a tall span only inflates the row
      #     it actually appears on.
      base_scale = slot_scale || body_scale
      left = content_left(width)

      if align
        vis = visible_width_scaled(text, base_scale)
        left = compute_pad(width, vis, align)
      end

      max_w = max_text_width(width, left, base_scale)
      segments = Parser.parse_inline(text)
      wrapped = wrap_segments(segments, max_w, base_scale)

      wrapped.each do |line_segs|
        line_h = max_segment_scale(line_segs, base_scale)
        term_move(row, left + 1)
        @terminal.write render_segments_scaled(line_segs, base_scale, line_height: line_h)
        row += line_h
      end
      row
    end

    def render_code_block(block, width, row)
      code_lines = block[:content].lines.map(&:chomp)
      return row + body_scale if code_lines.empty?

      left = content_left(width)
      max_content_w = max_text_width(width, left, body_scale) - 4
      max_len = code_lines.map { |l| display_width(l) }.max
      box_content_w = [max_len, max_content_w].min

      highlighted = highlighted_code_lines(block, code_lines)

      highlighted.each_with_index do |line_tokens, li|
        fitted, used_w = fit_tokens_to_width(line_tokens, box_content_w)
        pad_len = [box_content_w - used_w, 0].max
        term_move(row, left + 1)
        @terminal.write ANSI[:gray_bg]
        @terminal.write KittyText.sized('  ', s: body_scale)
        fitted.each do |color, value|
          if color && !value.empty?
            code = color_code(color)
            @terminal.write code unless code.empty?
            @terminal.write KittyText.sized(value, s: body_scale)
            # Reset only the fg so the gray bg stays in effect.
            @terminal.write "\e[39m" unless code.empty?
          else
            @terminal.write KittyText.sized(value, s: body_scale) unless value.empty?
          end
        end
        @terminal.write KittyText.sized("#{' ' * pad_len}  ", s: body_scale)
        @terminal.write ANSI[:reset]
        row += body_scale
        # Defensive: ensure we don't leave the gray bg open between
        # adjacent code lines (the next line re-opens it).
        _ = li
      end

      row
    end

    # Tokenize fenced code through CodeHighlighter when a language is
    # set; fall back to a single uncolored token per line otherwise.
    # The returned shape is always `[[[color, value], …], …]` — one
    # outer array per code line, one inner pair per token, color is
    # nil for "default fg" runs.
    def highlighted_code_lines(block, code_lines)
      tokens = block[:language] && CodeHighlighter.highlight(block[:content], block[:language])
      return code_lines.map { |line| [[nil, line]] } unless tokens

      group_tokens_by_line(tokens, code_lines.size)
    end

    # Walk a flat token stream and split values containing "\n" so each
    # line gets its own array. The trailing newline on a token is
    # dropped — render_code_block emits line-by-line and newlines are
    # implicit between rows.
    def group_tokens_by_line(tokens, expected_lines)
      lines = [[]]
      tokens.each do |color, value|
        parts = value.split("\n", -1)
        parts.each_with_index do |part, idx|
          lines.last << [color, part] unless part.empty?
          lines << [] if idx < parts.size - 1
        end
      end
      # Pop a trailing empty line that comes from the source's final \n.
      lines.pop if lines.last.empty? && lines.size > expected_lines
      lines
    end

    # Walk tokens until the cumulative visible width hits `max_w`,
    # truncating the last partial token if needed. Returns the
    # fitted-token array and the total width it consumed (useful for
    # right-padding the line).
    def fit_tokens_to_width(line_tokens, max_w)
      out = []
      used = 0
      line_tokens.each do |color, value|
        avail = max_w - used
        break if avail <= 0
        w = display_width(value)
        if w <= avail
          out << [color, value]
          used += w
        else
          out << [color, truncate_to_width(value, avail)]
          used = max_w
          break
        end
      end
      [out, used]
    end

    def render_unordered_list(block, width, row)
      left = content_left(width)
      block[:items].each do |item|
        depth = item[:depth] || 0
        indent = '  ' * depth
        prefix = "#{indent}#{@theme.bullet[:text]}"
        prefix_w = display_width(prefix)
        # Plain text renders at body_scale; lines containing a sized
        # span (e.g. `<size=5>BIG</size>`) advance the row by that
        # span's height per-line. Mixing `body` and `BIG` on the same
        # line keeps body at body size — only the BIG span grows.
        base_scale = body_scale
        max_w = max_text_width(width, left, base_scale) - prefix_w

        segments = Parser.parse_inline(item[:text])
        wrapped = wrap_segments(segments, max_w, base_scale)

        wrapped.each_with_index do |line_segs, li|
          line_h = max_segment_scale(line_segs, base_scale)
          term_move(row, left)
          if li == 0
            @terminal.write "#{render_bullet(prefix)}#{render_segments_scaled(line_segs, base_scale, line_height: line_h)}"
          else
            @terminal.write "#{KittyText.sized(' ' * prefix_w, s: base_scale)}#{render_segments_scaled(line_segs, base_scale, line_height: line_h)}"
          end
          row += line_h
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
        base_scale = body_scale
        max_w = max_text_width(width, left, base_scale) - prefix_w

        segments = Parser.parse_inline(item[:text])
        wrapped = wrap_segments(segments, max_w, base_scale)

        wrapped.each_with_index do |line_segs, li|
          line_h = max_segment_scale(line_segs, base_scale)
          term_move(row, left)
          if li == 0
            @terminal.write "#{KittyText.sized(prefix, s: base_scale)}#{render_segments_scaled(line_segs, base_scale, line_height: line_h)}"
          else
            @terminal.write "#{KittyText.sized(' ' * prefix_w, s: base_scale)}#{render_segments_scaled(line_segs, base_scale, line_height: line_h)}"
          end
          row += line_h
        end
        row += 1
      end
      row
    end

    def render_definition_list(block, width, row)
      left = content_left(width)
      max_w = max_text_width(width, left, body_scale)

      segments = Parser.parse_inline(block[:term])
      wrapped = wrap_segments(segments, max_w, body_scale)
      wrapped.each do |line_segs|
        term_move(row, left)
        @terminal.write "#{ANSI[:bold]}#{render_segments_scaled(line_segs, body_scale)}#{ANSI[:reset]}"
        row += body_scale
      end

      def_max_w = [max_w - 4, 1].max
      block[:definition].each_line do |line|
        segments = Parser.parse_inline(line.chomp)
        wrapped = wrap_segments(segments, def_max_w, body_scale)
        wrapped.each do |line_segs|
          term_move(row, left + 4)
          @terminal.write render_segments_scaled(line_segs, body_scale)
          row += body_scale
        end
      end
      row
    end

    def render_blockquote(block, width, row)
      left = content_left(width)
      prefix = '| '
      prefix_w = display_width(prefix)
      max_w = max_text_width(width, left + 1, body_scale) - prefix_w

      block[:content].each_line do |line|
        text = line.chomp
        segments = [[:text, text]]
        wrapped = wrap_segments(segments, max_w, body_scale)

        wrapped.each_with_index do |line_segs, li|
          term_move(row, left + 1)
          p = li == 0 ? prefix : ' ' * prefix_w
          @terminal.write "#{ANSI[:dim]}#{KittyText.sized(p, s: body_scale)}#{render_segments_scaled(line_segs, body_scale)}#{ANSI[:reset]}"
          row += body_scale
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
          @terminal.write "#{ANSI[:bold]}#{KittyText.sized(line, s: body_scale)}#{ANSI[:reset]}"
        else
          @terminal.write KittyText.sized(line, s: body_scale)
        end
        row += body_scale

        if ri == 0
          term_move(row, left)
          @terminal.write KittyText.sized(col_widths.map { |w| '-' * w }.join('--+--'), s: body_scale)
          row += body_scale
        end
      end
      row
    end

    # Layout/flow dispatch for :image blocks. Fully-positioned images
    # (both x and y set) were already rendered in the slide's pre-pass
    # — skip them here so we don't re-emit the placement (which would
    # re-erase the cells that subsequent text writes have since
    # restored).
    def render_image_or_skip(block, width, row)
      attrs = effective_attrs(block)
      return row if attrs['x'] && attrs['y']
      render_image(block, width, row)
    end

    def render_image(block, width, row)
      path = resolve_image_path(block[:path])
      return row + body_scale unless File.exist?(path)

      img_size = ImageUtil.image_size(path)
      return row + body_scale unless img_size

      img_w, img_h = img_size
      cell_w, cell_h = @terminal.cell_pixel_size

      attrs = effective_attrs(block)
      # `<img>` x/y resolve with sub-cell pixel precision: each axis
      # comes back as `[anchor_cell, px_offset_within_anchor]`. The
      # anchor cell handles where to move the cursor for layering /
      # fallback paths; the px offset feeds Kitty Graphics' `X=`/`Y=`
      # so a "100px from the left" request lands at 100 px, not at
      # the nearest cell edge.
      abs_x_pair = resolve_at_coord(attrs['x'], @terminal.width, cell_px: cell_w, default_unit: :px, with_offset: true)
      abs_y_pair = resolve_at_coord(attrs['y'], @terminal.height, cell_px: cell_h, default_unit: :px, with_offset: true)
      abs_x, abs_x_off = abs_x_pair if abs_x_pair
      abs_y, abs_y_off = abs_y_pair if abs_y_pair
      # `x` or `y` (either / both) pins the image at that absolute cell;
      # the unspecified axis falls back to the flow default (centered
      # in `width` for x, the current `row` for y). Any explicit
      # positioning makes the image contribute 0 to the layout flow
      # — same as `<at>` — so a single-axis pin doesn't push the next
      # block past where the image landed.
      positioned = !abs_x.nil? || !abs_y.nil?

      # Compute the image's intrinsic size in cells. Default is to draw
      # at intrinsic size — no auto-fit shrinking. If the image is
      # larger than the available pane, the terminal clips the overflow
      # (same as a tall string of text scrolling off the bottom).
      #
      # `relative_height="N"` / `relative_width="N"` (set directly, or
      # via the `height="N%"` / `width="N%"` aliases) are explicit
      # author caps: they shrink the image proportionally so that no
      # axis exceeds N % of the terminal. They never grow it.
      img_cell_w = img_w.to_f / cell_w
      img_cell_h = img_h.to_f / cell_h
      scale = 1.0

      # Pixel sizing — `height="200"` / `width="300"` (plain integer,
      # optional `px` suffix) force-resizes the image to that pixel
      # target. Unlike `relative_*` caps, a pixel value can scale the
      # image UP as well as down — they're an exact "render at this
      # size" request, not a cap. Setting both shrinks to fit inside
      # the smaller of the two ratios (aspect ratio preserved).
      px_scale = nil
      if (h_px = parse_px_size(attrs['height']))
        px_scale = h_px / img_h.to_f
      end
      if (w_px = parse_px_size(attrs['width']))
        w_scale = w_px / img_w.to_f
        px_scale = px_scale ? [px_scale, w_scale].min : w_scale
      end
      scale = px_scale if px_scale

      # `relative_height="N"` / `relative_width="N"` (set directly, or
      # via the `height="N%"` / `width="N%"` aliases) are explicit
      # author caps: they shrink the image proportionally so that no
      # axis exceeds N % of the terminal. They never grow it, and they
      # win over a px sizing request when smaller.
      if (rh = attrs['relative_height']) && rh.to_i.positive?
        max_cell_h = @terminal.height * rh.to_i / 100.0
        scale = [scale, max_cell_h / img_cell_h].min
      end
      if (rw = attrs['relative_width']) && rw.to_i.positive?
        max_cell_w = @terminal.width * rw.to_i / 100.0
        scale = [scale, max_cell_w / img_cell_w].min
      end
      target_cols = [(img_cell_w * scale).to_i, 1].max
      target_rows = [(img_cell_h * scale).to_i, 1].max

      # Per-axis position: explicit `x` / `y` win; absent axes pick
      # up the flow default. `x_cell` folds the active slot offset
      # into the centered flow position so both move_to and
      # kitty_icat land in the right column when rendering inside a
      # layout slot. The absolute coords already name the screen
      # cell directly.
      y_cell = abs_y || row
      x_cell = abs_x || ([(width - target_cols) / 2, 0].max + 1 + @x_offset)
      # Sub-cell pixel offsets only flow through when that axis was
      # explicitly positioned in pixel-form. Flow / centered / cell-
      # form values land on cell boundaries and pass 0.
      x_off = abs_x_off || 0
      y_off = abs_y_off || 0

      # Direct kitty-graphics upload for PNGs always; for non-PNG
      # raster formats only on Echoes — its NSBitmapImageRep-based
      # decoder treats `f=100` permissively (PNG / JPEG / TIFF / GIF /
      # BMP all decode through the same code path), so we can ship a
      # JPG via the same transmit + place pair the PNG path uses and
      # avoid the `kitten icat` subprocess. Stock kitty rejects non-
      # PNG bytes at `f=100` (EBADDATA), so we keep the icat fallback
      # for it. icat doesn't cope with placements that exceed the
      # visible cells, so the PNG path is also where intrinsic-size
      # oversize images work cleanly.
      if ImageUtil.kitty_terminal? && (ImageUtil.png?(path) || KittyText.echoes?)
        image_id = ensure_kitty_uploaded(path)
        @terminal.move_to(y_cell, x_cell)
        # z layering: explicit `z="..."` attr wins. With no z attr, an
        # image rendered in slide flow stays on top of cells (default
        # Kitty z=0 behavior) — that's what authors want for the
        # common single-image-per-slide case. A pinned image (both x
        # and y given) is more likely to be sitting under other slide
        # content, so it defaults to z=-1 (behind text) — same trick
        # `<bg image="..."/>` uses. Authors can override with z="0"
        # / z="1" / etc. when they want the image on top of text.
        z = if attrs['z']
              attrs['z'].to_i
            elsif abs_x && abs_y
              -1
            else
              nil
            end
        @terminal.write ImageUtil.kitty_place(image_id: image_id, cols: target_cols, rows: target_rows, z: z, x_off: x_off, y_off: y_off)
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

      positioned ? row : row + target_rows
    end

    # Parse an `<img>` height / width attribute as a pixel target.
    # Accepts `"200"` and `"200px"` (CSS-style suffix, forgiving). A
    # bare integer with no unit is interpreted as pixels. `nil` /
    # empty / a percent value / anything non-numeric returns nil so
    # the caller falls back to relative or intrinsic sizing.
    def parse_px_size(raw)
      return nil unless raw.is_a?(String)
      m = raw.match(/\A(\d+)(?:px)?\z/)
      m ? m[1].to_i : nil
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

    # Upload any inline image bytes (currently used by shape SVGs) once
    # via Kitty graphics direct-data transmission. Keyed by SHA1 so
    # identical shapes on multiple slides dedup. Shares the
    # @kitty_uploads cache (and id counter) with PNG / file uploads.
    def ensure_kitty_inline_uploaded(bytes)
      require 'digest'
      key = [:inline, Digest::SHA1.hexdigest(bytes.to_s)]
      return @kitty_uploads[key] if @kitty_uploads.key?(key)

      image_id = @kitty_uploads.size + 1
      @terminal.write ImageUtil.kitty_upload_inline(bytes, image_id: image_id)
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
      sized =
        if size && size < body_scale
          KittyText.sized(prefix, s: body_scale, n: size, d: body_scale, v: 2)
        else
          KittyText.sized(prefix, s: size || body_scale)
        end
      color = @theme.bullet[:color]
      return sized unless color && !color.to_s.empty?
      "#{color_code(color.to_s)}#{sized}#{ANSI[:reset]}"
    end

    # Render a <font face="..." size="..." color="..."> run. The face goes out
    # via OSC 66 f= (Echoes extension); the size resolves through the same
    # SIZE_SCALES table that <size=N> uses; the color wraps in the same ANSI
    # escape that <color=NAME> uses. `line_height:` lets a small font ride
    # at the bottom of a taller line (see `sized_in_line`).
    def render_font_segment(content, attrs, para_scale, line_height: nil, mixed_line: false, default_face: nil, default_h: nil)
      scale = (attrs[:size] && Parser::SIZE_SCALES[attrs[:size]]) || para_scale
      base = sized_in_line(content, seg_scale: scale, line_height: line_height, mixed_line: mixed_line, f: attrs[:face] || default_face, h: default_h)
      color = attrs[:color]
      return base unless color
      "#{color_code(color)}#{base}#{ANSI[:reset]}"
    end

    # Wrap `content` in OSC 66 so segments on a mixed-size line share a
    # typographic baseline (not just a block-bottom edge). All segments
    # emit `s=line_height` so their multicell blocks have the same top
    # and bottom; then `v=3` (Echoes-private baseline-align mode) tells
    # the renderer to position each one so its baseline lands at the
    # same y within the block, regardless of font/scale.
    #
    #   - Shorter than line_height → s=line_height,n=seg,d=line_height,v=3.
    #     Block matches the tallest sibling; glyph drawn at seg/line_height
    #     ratio; baseline shared with the tall siblings.
    #
    #   - Equal to line_height but on a mixed line → s=seg_scale,v=3.
    #     Same block size as the shorter siblings (since they all emit
    #     s=line_height too). v=3 keeps everyone on the same baseline.
    #
    #   - Anything when line_height is nil OR no mixed-size line at all →
    #     plain `s=seg_scale`. Byte-identical to the pre-line-height path
    #     so single-scale paragraphs / lists / etc. don't drift.
    #
    # `mixed_line:` tells the helper whether *some other* segment on this
    # line is shorter than line_height — the caller computes it once per
    # line because the helper itself only sees one segment at a time.
    #
    # Echoes' v= mapping (echoes/lib/echoes/gui.rb:1269):
    #   v=0 (default) → top
    #   v=1           → text-bottom at block-bottom
    #   v=2           → text-centered in block
    #   v=3           → baseline at `block_bottom - cell_h + default_ascender`
    #                   (Echoes-private; falls back to top on strict kitty)
    def sized_in_line(content, seg_scale:, line_height:, mixed_line: false, f: nil, h: nil)
      if line_height && line_height > seg_scale
        KittyText.sized(content, s: line_height, n: seg_scale, d: line_height, v: 3, f: f, h: h)
      elsif mixed_line
        KittyText.sized(content, s: seg_scale, v: 3, f: f, h: h)
      else
        KittyText.sized(content, s: seg_scale, f: f, h: h)
      end
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
    def render_segments_scaled(segments, para_scale, line_height: nil, default_face: :body, default_h: nil, default_color: :body)
      f = default_face == :body ? (slot_family || @theme.font[:family]) : default_face
      h = default_h
      c = default_color == :body ? (slot_color || @theme.font[:color]) : default_color
      body_open = c ? color_code(c) : ''
      # "Mixed line" = line_height is set AND at least one segment is
      # shorter than line_height. When true, the tall segment(s) also
      # get v=1 so they share the baseline with the shorter siblings
      # (otherwise tall floats to the top and short to the bottom).
      mixed = line_height &&
        segments.any? { |s| s[0] != :break && effective_seg_scale(s, para_scale) < line_height }
      # When `line_height` isn't passed, callers want the pre-mixed-size
      # behavior — sized_in_line collapses to plain `s=seg_scale`, so
      # existing wire-shape tests keep their byte-for-byte output.
      inner = segments.map { |segment|
        type = segment[0]
        content = segment[1]
        case type
        when :tag
          tag_name = segment[2]
          if (scale = Parser::SIZE_SCALES[tag_name])
            sized_in_line(content, seg_scale: scale, line_height: line_height, mixed_line: mixed, f: f, h: h)
          elsif !(code = color_code(tag_name)).empty?
            # `<color=NAME>`, `<color=ff5555>`, `<color=#ff5555>`, the
            # kramdown `{::tag name="red"}` form — anything color_code
            # can resolve gets wrapped in that SGR. Same engine
            # `<font color="...">` uses, so the two stay in sync.
            "#{code}#{sized_in_line(content, seg_scale: para_scale, line_height: line_height, mixed_line: mixed, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
          else
            sized_in_line(content, seg_scale: para_scale, line_height: line_height, mixed_line: mixed, f: f, h: h)
          end
        when :font          then "#{render_font_segment(content, segment[2] || {}, para_scale, line_height: line_height, mixed_line: mixed, default_face: f, default_h: h)}#{(segment[2] || {})[:color] ? body_open : ''}"
        when :note          then @mode == :audience ? "" : "#{ANSI[:dim]}#{sized_in_line(content, seg_scale: para_scale, line_height: line_height, mixed_line: mixed, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :bold          then "#{ANSI[:bold]}#{sized_in_line(content, seg_scale: para_scale, line_height: line_height, mixed_line: mixed, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :italic        then "#{ANSI[:italic]}#{sized_in_line(content, seg_scale: para_scale, line_height: line_height, mixed_line: mixed, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :strikethrough then "#{ANSI[:strikethrough]}#{sized_in_line(content, seg_scale: para_scale, line_height: line_height, mixed_line: mixed, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :code          then "#{ANSI[:gray_bg]}#{sized_in_line(" #{content} ", seg_scale: para_scale, line_height: line_height, mixed_line: mixed, f: f, h: h)}#{ANSI[:reset]}#{body_open}"
        when :text          then sized_in_line(content, seg_scale: para_scale, line_height: line_height, mixed_line: mixed, f: f, h: h)
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
    def wrap_segments(segments, max_width, para_scale = body_scale)
      # Force-break support: split at `:break` segments (from <br>),
      # wrap each chunk independently against `max_width`, then
      # concatenate the resulting lines. An empty chunk (two `<br>`s
      # in a row, or a leading / trailing `<br>`) yields one blank
      # line, matching HTML semantics.
      if segments.any? { |s| s[0] == :break }
        groups = [[]]
        segments.each do |seg|
          seg[0] == :break ? (groups << []) : (groups.last << seg)
        end
        return groups.flat_map { |g| wrap_segments(g, max_width, para_scale) }
      end

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

    # Largest OSC 66 scale used inside the paragraph's inline markup,
    # used by callers to decide how many rows to advance the layout
    # row by per text line. Recognizes all three size-bearing
    # spellings: the kramdown `{::tag name="..."}`, the XML
    # `<size=N>`, and `<font size="..."/>` — each emits OSC 66 text
    # that occupies `N` cells tall, so a list item or paragraph
    # carrying any of them needs the row to advance by N rather
    # than the body scale.
    def max_inline_scale(text)
      max = 0
      [
        /\{::tag\s+name="([^"]+)"\}/,
        /<size=(?:"([^"]*)"|'([^']*)'|([^>\s]+))>/,
        /<font\b[^>]*\bsize=["']?([^"'\s>]+)/
      ].each do |re|
        text.scan(re) do |groups|
          value = Array(groups).compact.first
          scale = Parser::SIZE_SCALES[value]
          max = scale if scale && scale > max
        end
      end
      max > 0 ? max : nil
    end

    def visible_width_scaled(text, default_scale)
      Parser.parse_inline(text).sum { |segment|
        content = segment[1] || ''
        display_width(content) * effective_seg_scale(segment, default_scale)
      }
    end

    # Resolve a CSS-ish color value into an opening ANSI SGR escape.
    # Accepts: a named ANSI color (`red`, `bright_cyan`, …), a 6-digit
    # hex code (`ff5555`, with or without a leading `#`). Returns `''`
    # for an unrecognized value so callers can no-op safely.
    def color_code(color)
      c = color.to_s.sub(/\A#/, '')
      if (code = Parser::NAMED_COLORS[c])
        "\e[#{code}m"
      elsif c.match?(/\A[0-9a-fA-F]{6}\z/)
        r, g, b = c.scan(/../).map { |h| h.to_i(16) }
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
