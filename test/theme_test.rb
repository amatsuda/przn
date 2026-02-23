# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ThemeTest < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry @tmpdir
  end

  sub_test_case ".default" do
    test "returns theme with default colors" do
      theme = Przn::Theme.default
      assert_equal '1e1e2e', theme.colors[:background]
      assert_equal 'cdd6f4', theme.colors[:foreground]
      assert_equal '313244', theme.colors[:code_bg]
      assert_equal '6c7086', theme.colors[:dim]
      assert_equal 'a6e3a1', theme.colors[:inline_code]
      assert_nil theme.colors[:heading]
    end

    test "returns theme with default font" do
      theme = Przn::Theme.default
      assert_nil theme.font[:family]
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
      assert_equal 'cdd6f4', theme.colors[:foreground]
      assert_equal '313244', theme.colors[:code_bg]
      assert_equal '6c7086', theme.colors[:dim]
      assert_equal 'a6e3a1', theme.colors[:inline_code]
      assert_nil theme.font[:family]
    end

    test "empty file falls back to all defaults" do
      write_theme ""

      theme = Przn::Theme.load(theme_path)
      assert_equal '1e1e2e', theme.colors[:background]
      assert_equal 'cdd6f4', theme.colors[:foreground]
    end

    test "missing file raises error" do
      assert_raise(ArgumentError) do
        Przn::Theme.load("/nonexistent/theme.yml")
      end
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
