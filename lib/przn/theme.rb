# frozen_string_literal: true

require 'yaml'

module Przn
  class Theme
    DEFAULT_PATH = File.expand_path('../../../default_theme.yml', __FILE__)

    attr_reader :colors, :font, :bullet, :bullet_size, :bg, :heading_face

    def self.load(path)
      raise ArgumentError, "Theme file not found: #{path}" unless File.exist?(path)

      defaults = load_yaml(DEFAULT_PATH)
      overrides = load_yaml(path)
      merged = {
        colors: defaults[:colors].merge(overrides[:colors] || {}),
        font: defaults[:font].merge(overrides[:font] || {}),
        bullet: overrides[:bullet] || defaults[:bullet],
        bullet_size: overrides[:bullet_size] || defaults[:bullet_size],
        bg: defaults[:bg].merge(overrides[:bg] || {}),
        heading_face: overrides[:heading_face] || defaults[:heading_face],
      }
      new(merged)
    end

    def self.default
      new(load_yaml(DEFAULT_PATH))
    end

    def self.load_yaml(path)
      data = YAML.safe_load_file(path, symbolize_names: true) || {}
      {
        colors: data[:colors] || {},
        font: data[:font] || {},
        bullet: data[:bullet],
        bullet_size: data[:bullet_size],
        bg: (data[:bg] || {}).compact,
        heading_face: data[:heading_face],
      }
    end
    private_class_method :load_yaml

    def initialize(config)
      @colors = config[:colors]
      @font = config[:font]
      @bullet = config[:bullet]
      @bullet_size = config[:bullet_size]
      @bg = config[:bg]
      @heading_face = config[:heading_face]
    end
  end
end
