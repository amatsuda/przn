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
    test 'colors: section is empty by default (legacy palette retired)' do
      # `colors:` used to hold a Prawn-only palette (code_bg / dim /
      # inline_code). Those have moved into per-feature theme keys
      # (`code.bg`, `code.inline_color`, `counter.color`) and the
      # default_theme.yml no longer pre-populates `colors:`. The
      # exporter's hardcoded DEFAULT_* constants take over when no
      # override is set.
      theme = Przn::Theme.default
      assert_empty theme.colors, 'default colors: should be empty after the legacy-palette retirement'
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

    test 'counter ships rabbit / turtle runner glyphs; color and duration unset by default' do
      counter = Przn::Theme.default.counter
      assert_nil counter[:color]
      assert_nil counter[:duration]
      # The runner emojis live in the theme as raw escape sequences so
      # users can swap them out without touching the renderer.
      assert_match(/🐇/, counter[:rabbit])
      assert_match(/🐢/, counter[:turtle])
    end

    test 'ships built-in layouts (default, cover, title-only, takahashi, title-content, two-column, photo-caption)' do
      layouts = Przn::Theme.default.layouts
      assert_equal %w[default cover title-only takahashi title-content two-column photo-caption].sort,
                   layouts.keys.sort
      assert_equal %w[title left right], layouts['two-column'].map(&:name)
      assert_equal '50%', layouts['two-column'].find { |s| s.name == 'right' }.x
    end

    test 'shipped `takahashi` is a single very-large centered slot (高橋メソッド)' do
      slots = Przn::Theme.default.layouts['takahashi']
      assert_equal 1, slots.size
      slot = slots[0]
      assert_equal 'title',      slot.name
      assert_equal 'center',     slot.x, 'takahashi title slot should be x: center'
      assert_equal 'center',     slot.y, 'takahashi title slot should be y: center (content-measured centering)'
      assert_equal 'xxxx-large', slot.size
    end

    test 'shipped `default` mirrors `title-content` (centered title band + content below)' do
      defaults = Przn::Theme.default.layouts
      assert_equal defaults['title-content'].map(&:to_a),
                   defaults['default'].map(&:to_a)
    end

    test 'shipped `cover` has a centered title slot and a bottom subtitle slot' do
      slots = Przn::Theme.default.layouts['cover']
      assert_equal %w[title subtitle], slots.map(&:name)
      assert_equal '35%', slots[0].y
      assert_equal '80%', slots[1].y
      assert_equal 'center', slots[0].x
      assert_equal 'center', slots[1].x
    end

    test 'every built-in title slot opts into center alignment via x: center' do
      layouts = Przn::Theme.default.layouts
      %w[default cover title-only takahashi title-content two-column photo-caption].each do |name|
        title = layouts[name].find { |s| s.name == 'title' }
        assert_equal 'center', title.x, "expected #{name}.title to have x: center"
      end
    end

    test '`default` content slot uses numeric x (flush-left, no keyword)' do
      content = Przn::Theme.default.layouts['default'].find { |s| s.name == 'content' }
      assert_equal '5', content.x, 'content slot should be at column 5, default left alignment'
    end

    test 'slot accepts size / family / color from YAML' do
      write_theme <<~YAML
        layouts:
          fancy:
            - {name: title, x: 1, y: 1, width: 100%, height: 5, size: xxx-large, family: Menlo, color: red}
      YAML

      slot = Przn::Theme.load(theme_path).layouts['fancy'][0]
      assert_equal 'xxx-large', slot.size
      assert_equal 'Menlo',     slot.family
      assert_equal 'red',       slot.color
    end

    test 'shipped `cover.title` opts into a larger size (Keynote-style title slide)' do
      title = Przn::Theme.default.layouts['cover'].find { |s| s.name == 'title' }
      assert_equal 'xxx-large', title.size
    end
  end

  sub_test_case '.parse_duration' do
    test 'parses minutes' do
      assert_equal 1800, Przn::Theme.parse_duration('30m')
    end

    test 'parses hours + minutes' do
      assert_equal 5400, Przn::Theme.parse_duration('1h30m')
    end

    test 'parses hours + minutes + seconds' do
      assert_equal 3723, Przn::Theme.parse_duration('1h2m3s')
    end

    test 'parses plain integer string as seconds' do
      assert_equal 45, Przn::Theme.parse_duration('45')
    end

    test 'parses bare integer / numeric as seconds' do
      assert_equal 45, Przn::Theme.parse_duration(45)
    end

    test 'returns nil for nil / empty / garbage' do
      assert_nil Przn::Theme.parse_duration(nil)
      assert_nil Przn::Theme.parse_duration('')
      assert_nil Przn::Theme.parse_duration('garbage')
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

    test 'custom layouts: section loads as an ordered list of Slot structs' do
      write_theme <<~YAML
        layouts:
          custom:
            - {name: title, x: 1, y: 1, width: 100%, height: 5}
            - {name: body,  x: 1, y: 7, width: 100%, height: 80%}
      YAML

      theme = Przn::Theme.load(theme_path)
      assert_equal %w[title body], theme.layouts['custom'].map(&:name)
      slot = theme.layouts['custom'][1]
      assert_equal ['body', '1', '7', '100%', '80%'],
                   [slot.name, slot.x, slot.y, slot.width, slot.height]
    end

    test 'default-named layout in theme.yml is loaded like any other layout' do
      write_theme <<~YAML
        layouts:
          default:
            - {name: title,   x: 5, y: 3,  width: 90%, height: 6}
            - {name: content, x: 5, y: 10, width: 90%, height: 80%}
      YAML

      theme = Przn::Theme.load(theme_path)
      assert_equal %w[title content], theme.layouts['default'].map(&:name)
    end

    test 'overriding a built-in layout replaces its slot list end-to-end' do
      write_theme <<~YAML
        layouts:
          two-column:
            - {name: title, x: 1, y: 1, width: 100%, height: 3}
            - {name: only,  x: 1, y: 4, width: 100%, height: 90%}
      YAML

      theme = Przn::Theme.load(theme_path)
      assert_equal %w[title only], theme.layouts['two-column'].map(&:name)
      # Other built-ins remain untouched.
      assert_equal @defaults.layouts['photo-caption'].map(&:name),
                   theme.layouts['photo-caption'].map(&:name)
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

    test 'user file sets counter.duration (opts into the runner bar)' do
      write_theme <<~YAML
        counter:
          duration: "30m"
      YAML

      assert_equal '30m', Przn::Theme.load(theme_path).counter[:duration]
    end

    test 'user file sets counter.color' do
      write_theme <<~YAML
        counter:
          color: cyan
      YAML

      assert_equal 'cyan', Przn::Theme.load(theme_path).counter[:color]
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
