# frozen_string_literal: true

require 'yaml'

module Przn
  class Theme
    DEFAULT_PATH = File.expand_path('../../../default_theme.yml', __FILE__)

    # A rectangular region inside a slide. `x` / `y` are the 1-based
    # cell coords of the slot's top-left; `width` / `height` are sizes
    # in cells. All four are stored as the raw strings from the YAML
    # ("5", "50%", "90%") and resolved at render time against the
    # current terminal width / height by the same helper that handles
    # `<at x y>` and `<img x y>` coords. `align` is the default
    # horizontal alignment for blocks rendered into this slot (:left,
    # :center, :right, or nil = :left); a per-block `<center>` /
    # `{:.center}` still wins over the slot default.
    Slot = Struct.new(:name, :x, :y, :width, :height, :align)

    attr_reader :colors, :font, :bullet, :background, :title, :rabbit, :layouts

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
        # `rabbit` is opt-in: absent → nil → renderer uses the plain N/M footer.
        # Present (even as an empty block) → hash → renderer uses the runner bar.
        rabbit: defaults[:rabbit] || overrides[:rabbit] ?
          (defaults[:rabbit] || {}).merge(overrides[:rabbit] || {}) :
          nil,
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
        # nil when the `rabbit:` key isn't in the YAML at all (opt-in feature);
        # empty hash when it's present but childless.
        rabbit: data.key?(:rabbit) ? (data[:rabbit] || {}).compact : nil,
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
          Slot.new(h[:name].to_s, h[:x].to_s, h[:y].to_s, h[:width].to_s, h[:height].to_s, h[:align]&.to_sym)
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
      @rabbit = config[:rabbit]
      @layouts = config[:layouts] || {}
    end
  end
end
