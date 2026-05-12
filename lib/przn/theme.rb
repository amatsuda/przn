# frozen_string_literal: true

require 'yaml'

module Przn
  class Theme
    DEFAULT_PATH = File.expand_path('../../../default_theme.yml', __FILE__)

    attr_reader :colors, :font, :bullet, :background, :title

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
        bullet: (data[:bullet] || {}).compact,
        background: (data[:background] || {}).compact,
        title: (data[:title] || {}).compact,
      }
    end
    private_class_method :load_yaml

    def initialize(config)
      @colors = config[:colors]
      @font = config[:font]
      @bullet = config[:bullet]
      @background = config[:background]
      @title = config[:title]
    end
  end
end
