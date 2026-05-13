# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class ThemeTest < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @defaults = Przn::Theme.default
  end

  def teardown
    FileUtils.remove_entry @tmpdir
  end

  sub_test_case '.default' do
    test 'returns theme with colors from default_theme.yml' do
      theme = Przn::Theme.default
      assert_equal '313244', theme.colors[:code_bg]
      assert_equal '6c7086', theme.colors[:dim]
      assert_equal 'a6e3a1', theme.colors[:inline_code]
      assert_nil theme.colors[:background]
      assert_nil theme.colors[:foreground]
      assert_nil theme.colors[:heading]
    end

    test 'returns theme with default font' do
      theme = Przn::Theme.default
      assert_nil theme.font[:family]
    end

    test 'returns theme with default bullet text and unset size' do
      bullet = Przn::Theme.default.bullet
      assert_equal '・', bullet[:text]
      assert_nil bullet[:size]
    end

    test 'default background is empty (renderer emits no override)' do
      assert_equal({}, Przn::Theme.default.background)
    end

    test 'default title is empty (renderer uses h1 defaults; no OSC 66 f=, no color)' do
      assert_equal({}, Przn::Theme.default.title)
    end
  end

  sub_test_case '.load' do
    test 'reads YAML and overrides specified values' do
      write_theme <<~YAML
        colors:
          code_bg: "ff0000"
          dim: "00ff00"
        font:
          family: "HackGen"
      YAML

      theme = Przn::Theme.load(theme_path)
      assert_equal 'ff0000', theme.colors[:code_bg]
      assert_equal '00ff00', theme.colors[:dim]
      assert_equal 'HackGen', theme.font[:family]
    end

    test 'unspecified values fall back to defaults' do
      write_theme <<~YAML
        colors:
          dim: "ff0000"
      YAML

      theme = Przn::Theme.load(theme_path)
      assert_equal 'ff0000', theme.colors[:dim]
      assert_equal @defaults.colors[:code_bg], theme.colors[:code_bg]
      assert_equal @defaults.colors[:inline_code], theme.colors[:inline_code]
      assert_nil theme.font[:family]
    end

    test 'empty file falls back to all defaults' do
      write_theme ''

      theme = Przn::Theme.load(theme_path)
      assert_equal @defaults.colors[:code_bg], theme.colors[:code_bg]
      assert_equal @defaults.colors[:dim], theme.colors[:dim]
    end

    test 'missing file raises error' do
      assert_raise(ArgumentError) do
        Przn::Theme.load('/nonexistent/theme.yml')
      end
    end
  end

  sub_test_case '.auto_discover' do
    test 'loads a sibling theme.yml when one exists next to the deck' do
      write_theme <<~YAML
        bullet:
          text: "●"
      YAML
      deck = File.join(@tmpdir, 'deck.md')
      File.write(deck, "# T\n")

      theme = Przn::Theme.auto_discover(near: deck)
      assert_equal '●', theme.bullet[:text]
    end

    test 'returns nil when no theme.yml is alongside the deck' do
      deck = File.join(@tmpdir, 'deck.md')
      File.write(deck, "# T\n")

      assert_nil Przn::Theme.auto_discover(near: deck)
    end

    test 'user file overrides bullet.text' do
      write_theme <<~YAML
        bullet:
          text: "●"
      YAML

      bullet = Przn::Theme.load(theme_path).bullet
      assert_equal '●', bullet[:text]
      assert_nil bullet[:size]
    end

    test 'user file overrides bullet.size, keeps default text' do
      write_theme <<~YAML
        bullet:
          size: 1
      YAML

      bullet = Przn::Theme.load(theme_path).bullet
      assert_equal '・', bullet[:text]
      assert_equal 1, bullet[:size]
    end

    test 'unspecified bullet falls back to all defaults' do
      write_theme <<~YAML
        colors:
          code_bg: "ff0000"
      YAML

      assert_equal @defaults.bullet, Przn::Theme.load(theme_path).bullet
    end

    test 'user file sets a solid background color' do
      write_theme <<~YAML
        background:
          color: "#1a1a2e"
      YAML

      assert_equal({color: '#1a1a2e'}, Przn::Theme.load(theme_path).background)
    end

    test 'user file sets a gradient background' do
      write_theme <<~YAML
        background:
          from: "#1a1a2e"
          to:   "#16213e"
          angle: 90
      YAML

      bg = Przn::Theme.load(theme_path).background
      assert_equal '#1a1a2e', bg[:from]
      assert_equal '#16213e', bg[:to]
      assert_equal 90,        bg[:angle]
    end

    test 'user file sets a title family / size / color' do
      write_theme <<~YAML
        title:
          family: "Helvetica Neue"
          size: "7"
          color: "ff5555"
      YAML

      title = Przn::Theme.load(theme_path).title
      assert_equal 'Helvetica Neue', title[:family]
      assert_equal '7',              title[:size]
      assert_equal 'ff5555',         title[:color]
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
