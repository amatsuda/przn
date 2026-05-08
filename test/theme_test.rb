# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ThemeTest < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @defaults = Przn::Theme.default
  end

  def teardown
    FileUtils.remove_entry @tmpdir
  end

  sub_test_case ".default" do
    test "returns theme with colors from default_theme.yml" do
      theme = Przn::Theme.default
      assert_equal '000000', theme.colors[:background]
      assert_equal 'ffffff', theme.colors[:foreground]
      assert_equal '313244', theme.colors[:code_bg]
      assert_equal '6c7086', theme.colors[:dim]
      assert_equal 'a6e3a1', theme.colors[:inline_code]
      assert_nil theme.colors[:heading]
    end

    test "returns theme with default font" do
      theme = Przn::Theme.default
      assert_nil theme.font[:family]
    end

    test "returns theme with default bullet" do
      assert_equal "・", Przn::Theme.default.bullet
    end

    test "returns nil bullet_size by default (renderer falls back to body scale)" do
      assert_nil Przn::Theme.default.bullet_size
    end

    test "default bg is empty (renderer emits no override)" do
      assert_equal({}, Przn::Theme.default.bg)
    end
  end

  sub_test_case ".load" do
    test "reads YAML and overrides specified values" do
      write_theme <<~YAML
        colors:
          background: "ff0000"
          foreground: "00ff00"
        font:
          family: "HackGen"
      YAML

      theme = Przn::Theme.load(theme_path)
      assert_equal 'ff0000', theme.colors[:background]
      assert_equal '00ff00', theme.colors[:foreground]
      assert_equal 'HackGen', theme.font[:family]
    end

    test "unspecified values fall back to defaults" do
      write_theme <<~YAML
        colors:
          background: "ff0000"
      YAML

      theme = Przn::Theme.load(theme_path)
      assert_equal 'ff0000', theme.colors[:background]
      assert_equal @defaults.colors[:foreground], theme.colors[:foreground]
      assert_equal @defaults.colors[:code_bg], theme.colors[:code_bg]
      assert_equal @defaults.colors[:dim], theme.colors[:dim]
      assert_equal @defaults.colors[:inline_code], theme.colors[:inline_code]
      assert_nil theme.font[:family]
    end

    test "empty file falls back to all defaults" do
      write_theme ""

      theme = Przn::Theme.load(theme_path)
      assert_equal @defaults.colors[:background], theme.colors[:background]
      assert_equal @defaults.colors[:foreground], theme.colors[:foreground]
    end

    test "missing file raises error" do
      assert_raise(ArgumentError) do
        Przn::Theme.load("/nonexistent/theme.yml")
      end
    end

    test "user file overrides the bullet" do
      write_theme <<~YAML
        bullet: "●"
      YAML

      assert_equal "●", Przn::Theme.load(theme_path).bullet
    end

    test "unspecified bullet falls back to default" do
      write_theme <<~YAML
        colors:
          background: "ff0000"
      YAML

      assert_equal @defaults.bullet, Przn::Theme.load(theme_path).bullet
    end

    test "user file overrides bullet_size" do
      write_theme <<~YAML
        bullet_size: 1
      YAML

      assert_equal 1, Przn::Theme.load(theme_path).bullet_size
    end

    test "unspecified bullet_size falls back to default (nil)" do
      write_theme <<~YAML
        bullet: "●"
      YAML

      assert_nil Przn::Theme.load(theme_path).bullet_size
    end

    test "user file sets a solid bg color" do
      write_theme <<~YAML
        bg:
          color: "#1a1a2e"
      YAML

      assert_equal({color: "#1a1a2e"}, Przn::Theme.load(theme_path).bg)
    end

    test "user file sets a gradient bg" do
      write_theme <<~YAML
        bg:
          from: "#1a1a2e"
          to:   "#16213e"
          angle: 90
      YAML

      bg = Przn::Theme.load(theme_path).bg
      assert_equal "#1a1a2e", bg[:from]
      assert_equal "#16213e", bg[:to]
      assert_equal 90,        bg[:angle]
    end
  end

  private

  def theme_path
    File.join(@tmpdir, 'theme.yml')
  end

  def write_theme(content)
    File.write(theme_path, content)
  end
end
