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

    attr_reader :colors, :font, :bullet, :background, :title, :counter, :code, :layouts

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
        # Layouts: per-name replacement (no deep merge across slot lists —
        # an override redefines that layout's slot list end-to-end). The
        # name `default` is special: when a slide has no `{layout=...}`
        # IAL the renderer looks it up here. Themes that don't define
        # `layouts.default` keep the legacy flow behavior.
        layouts: defaults[:layouts].merge(overrides[:layouts] || {})
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
        layouts: parse_layouts(data[:layouts])
      }
    end
    private_class_method :load_yaml

    # Turn the raw `layouts:` YAML into a `{name => [Slot, ...]}` map.
    # Each layout's value is just the ordered slot list (no enclosing
    # `slots:` key in v1 since there's no other per-layout metadata
    # — promoting to a hash later is a one-line shape change).
    def self.parse_layouts(raw)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(name, slot_list), out|
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

    def initialize(config)
      @colors = config[:colors]
      @font = config[:font]
      @bullet = config[:bullet]
      @background = config[:background]
      @title = config[:title]
      @code = config[:code] || {}
      @counter = config[:counter] || {}
      @layouts = config[:layouts] || {}
    end
  end
end
