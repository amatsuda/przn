# frozen_string_literal: true

require 'yaml'

module Przn
  class Theme
    DEFAULT_PATH = File.expand_path('../../../default_theme.yml', __FILE__)

    # A rectangular region inside a slide. `x` / `y` are stored as the
    # raw strings from the YAML and resolved at render time against
    # the current terminal width / height by the same helper that
    # handles `<at x y>` and `<img x y>` coords — so `x` accepts the
    # full vocabulary (cell, `%`, `c`, `px`, and the keyword forms
    # `left` / `center` / `right`). When `x` is a keyword, the slot's
    # effective starting column is computed against `width` AND the
    # alignment used for blocks routed into the slot is derived from
    # the same keyword (`x: center` → block align: center, slot
    # positioned so its centre lands on the slide's centre).
    #
    # `size` / `family` / `color` are per-slot text-style overrides:
    # `size` sets the base scale for h1 and paragraphs (accepts the
    # same names as inline `<size>`); `family` and `color` cascade
    # through render_segments_scaled to every text run in the slot.
    # Inline tags (`<size>`, `<font>`, `<color>`) still win
    # per-segment.
    Slot = Struct.new(:name, :x, :y, :width, :height, :size, :family, :color)

    attr_reader :colors, :font, :bullet, :background, :title, :counter, :code, :layouts, :layout_backgrounds, :transition, :fragment

    def self.load(path)
      raise ArgumentError, "Theme file not found: #{path}" unless File.exist?(path)

      defaults = load_yaml(DEFAULT_PATH)
      overrides = load_yaml(path)
      merged = {
        colors: defaults[:colors].merge(overrides[:colors] || {}),
        font: defaults[:font].merge(overrides[:font] || {}),
        bullet: defaults[:bullet].merge(overrides[:bullet] || {}),
        background: defaults[:background].merge(overrides[:background] || {}),
        title: defaults[:title].merge(overrides[:title] || {}),
        # `code` styles fenced code blocks (family / size / color / bg).
        # Unset keys fall through to: family → font.family, size →
        # body_scale, color → terminal default fg, bg → the legacy dim
        # gray ANSI 236.
        code: defaults[:code].merge(overrides[:code] || {}),
        # `counter` is always a hash; empty by default. `counter.duration`
        # opts into the 🐇 runner bar; without it the renderer shows the
        # plain " N / M " footer. `counter.color` styles both modes.
        counter: defaults[:counter].merge(overrides[:counter] || {}),
        # `transition` carries the slide-fade `duration:` (ms) used when
        # a slide opts in via `# Title {transition=fade}`. Empty by
        # default — the renderer's fallback duration kicks in.
        transition: defaults[:transition].merge(overrides[:transition] || {}),
        # `fragment` carries the per-fragment animation `duration:` (ms)
        # used by `<at fragment="fade-up">` and friends. Empty hash if the
        # user opts out entirely; the renderer falls back to its hardcoded
        # 300ms when the key is missing.
        fragment: defaults[:fragment].merge(overrides[:fragment] || {}),
        # Layouts: per-name replacement (no deep merge across slot lists —
        # an override redefines that layout's slot list end-to-end). The
        # name `default` is special: when a slide has no `{layout=...}`
        # IAL the renderer looks it up here. Themes that don't define
        # `layouts.default` keep the legacy flow behavior.
        layouts: defaults[:layouts].merge(overrides[:layouts] || {}),
        # Per-layout backgrounds follow their layout: redefining a
        # layout's slots drops the background the defaults gave it.
        layout_backgrounds: defaults[:layout_backgrounds]
          .reject { |name, _| overrides[:layouts].key?(name) }
          .merge(overrides[:layout_backgrounds])
      }
      new(merged)
    end

    # Convert a human-friendly duration string to seconds.
    #   "30m"     -> 1800
    #   "1h30m"   -> 5400
    #   "1h2m3s"  -> 3723
    #   "45"      -> 45  (bare integers are seconds)
    #   45        -> 45  (already a number)
    #   nil / ""  -> nil
    #   "garbage" -> nil
    def self.parse_duration(input)
      return nil if input.nil?
      return input.to_i if input.is_a?(Numeric)

      s = input.to_s.strip
      return nil if s.empty?
      return s.to_i if s =~ /\A\d+\z/

      m = s.match(/\A(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?\z/)
      return nil unless m && m[0] != ''
      h, mi, se = m[1].to_i, m[2].to_i, m[3].to_i
      h * 3600 + mi * 60 + se
    end

    def self.default
      new(load_yaml(DEFAULT_PATH))
    end

    # Look for a sibling `theme.yml` next to the given file and load it if
    # present, so a deck can ship its theme alongside the markdown without
    # the user having to pass `--theme` explicitly. Returns nil if no file
    # is found.
    def self.auto_discover(near:)
      candidate = File.join(File.dirname(File.expand_path(near)), 'theme.yml')
      File.exist?(candidate) ? load(candidate) : nil
    end

    def self.load_yaml(path)
      data = YAML.safe_load_file(path, symbolize_names: true) || {}
      {
        colors: data[:colors] || {},
        font: data[:font] || {},
        bullet: (data[:bullet] || {}).compact,
        background: (data[:background] || {}).compact,
        title: (data[:title] || {}).compact,
        code: (data[:code] || {}).compact,
        counter: (data[:counter] || {}).compact,
        transition: (data[:transition] || {}).compact,
        fragment: (data[:fragment] || {}).compact,
        layouts: parse_layouts(data[:layouts]),
        layout_backgrounds: parse_layout_backgrounds(data[:layouts])
      }
    end
    private_class_method :load_yaml

    # Turn the raw `layouts:` YAML into a `{name => [Slot, ...]}` map.
    # A layout's value is either the ordered slot list itself, or a
    # hash holding that list under `slots:` next to per-layout
    # settings (`background:`, see parse_layout_backgrounds). A hash
    # without `slots:` defines no slots, so a theme can give a
    # built-in layout a background and keep its slots.
    def self.parse_layouts(raw)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(name, slot_list), out|
        slot_list = slot_list[:slots] if slot_list.is_a?(Hash)
        next unless slot_list.is_a?(Array)
        out[name.to_s] = slot_list.map { |s|
          h = s.transform_keys(&:to_sym)
          # Back-compat: a legacy `align: center` (etc.) on a slot
          # used to be a separate knob from `x:`. The two were always
          # used together in practice — every built-in layout that
          # set `align:` paired it with an `x:` whose only job was
          # to leave room for the centred content. The new shape
          # collapses them into `x: <keyword>`, so an old `align:`
          # value overrides any numeric `x:` written alongside it.
          x = h[:align] ? h[:align].to_s : h[:x].to_s
          Slot.new(
            h[:name].to_s,
            x, h[:y].to_s, h[:width].to_s, h[:height].to_s,
            h[:size]&.to_s,
            h[:family]&.to_s,
            h[:color]&.to_s
          )
        }
      end
    end
    private_class_method :parse_layouts

    # The `background:` of each hash-form layout, as a
    # `{name => attrs}` map with the same keys as the top-level
    # `background:` section.
    def self.parse_layout_backgrounds(raw)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(name, layout), out|
        next unless layout.is_a?(Hash) && layout[:background].is_a?(Hash)
        out[name.to_s] = layout[:background].compact
      end
    end
    private_class_method :parse_layout_backgrounds

    # `bullet` as it applies to a list item `depth` levels in. Each
    # `nested:` level overrides the one above it key by key, and items
    # deeper than the last `nested:` keep that last level's style. A
    # level that sets `text` without `image` stops inheriting the
    # image, so a text marker can follow an image one.
    def bullet_at(depth)
      style_at(@bullet, depth) do |bullet, nested|
        bullet.delete(:image) if nested[:text] && !nested[:image]
      end
    end

    # The depth of the level that set the `bullet.size` in effect at
    # `depth`: 0 for the top-level `bullet.size`, or when none is set.
    def bullet_size_depth(depth)
      style = @bullet
      (1..depth).select { |d|
        style = style[:nested] if style.is_a?(Hash)
        style.is_a?(Hash) && style[:size]
      }.last || 0
    end

    # `font` as it applies to a list item `depth` levels in, inherited
    # through `nested:` the same way as `bullet_at`.
    def font_at(depth)
      style_at(@font, depth)
    end

    def initialize(config)
      @colors = config[:colors]
      @font = config[:font]
      @bullet = config[:bullet]
      @background = config[:background]
      @title = config[:title]
      @code = config[:code] || {}
      @counter = config[:counter] || {}
      @transition = config[:transition] || {}
      @fragment = config[:fragment] || {}
      @layouts = config[:layouts] || {}
      @layout_backgrounds = config[:layout_backgrounds] || {}
    end

    private

    # `style` with its first `depth` `nested:` levels merged in, each one
    # into the level above it. Yields after each merge.
    def style_at(style, depth)
      depth.times do
        nested = style[:nested]
        break unless nested.is_a?(Hash)

        style = style.merge(nested.compact)
        yield style, nested if block_given?
      end
      style.reject { |key, _| key == :nested }
    end
  end
end
