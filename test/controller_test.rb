# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class ControllerTest < Test::Unit::TestCase
  # Minimal stubs — Controller#reload only touches Presentation,
  # Renderer#theme=, and Renderer#render via render_current.
  class FakeTerminal
    def write(_); end
    def flush; end
  end

  class FakeRenderer
    attr_accessor :theme, :renders
    def initialize; @renders = 0; end
    def render(*, **)
      @renders += 1
    end
    def preload(_); end
  end

  def setup
    @term = FakeTerminal.new
    @renderer = FakeRenderer.new
  end

  sub_test_case 'reload' do
    test 're-parses the deck from disk and updates @presentation' do
      tmp = Tempfile.new(['reload', '.md'])
      tmp.write("# A\n\nfirst\n")
      tmp.flush
      ps = Przn::Parser.parse(File.read(tmp.path))
      c = Przn::Controller.new(ps, @term, @renderer, source_file: tmp.path)

      tmp.rewind
      tmp.write("# A\n\nfirst\n\n# B\n\nsecond\n\n# C\n\nthird\n")
      tmp.flush

      c.send(:reload)
      new_ps = c.instance_variable_get(:@presentation)
      assert_equal 3, new_ps.total
    ensure
      tmp&.close!
    end

    test 'clamps the current slide index to the new total when slides were removed' do
      tmp = Tempfile.new(['reload', '.md'])
      tmp.write("# A\n\n# B\n\n# C\n")
      tmp.flush
      ps = Przn::Parser.parse(File.read(tmp.path))
      ps.go_to(2)  # was on slide 3 of 3
      c = Przn::Controller.new(ps, @term, @renderer, source_file: tmp.path)

      tmp.rewind
      tmp.truncate(0)
      tmp.write("# Only\n")
      tmp.flush

      c.send(:reload)
      new_ps = c.instance_variable_get(:@presentation)
      assert_equal 1, new_ps.total
      assert_equal 0, new_ps.current
    ensure
      tmp&.close!
    end

    test 'preserves the current slide index when within new bounds' do
      tmp = Tempfile.new(['reload', '.md'])
      tmp.write("# A\n\n# B\n\n# C\n")
      tmp.flush
      ps = Przn::Parser.parse(File.read(tmp.path))
      ps.go_to(1)  # slide 2 of 3
      c = Przn::Controller.new(ps, @term, @renderer, source_file: tmp.path)

      tmp.rewind
      tmp.write("# A\n\n# B-edited\n\n# C\n\n# D\n")
      tmp.flush

      c.send(:reload)
      new_ps = c.instance_variable_get(:@presentation)
      assert_equal 1, new_ps.current
    ensure
      tmp&.close!
    end

    test 'reloads theme.yml at the given path' do
      deck = Tempfile.new(['reload', '.md'])
      deck.write("# A\n")
      deck.flush
      theme_file = Tempfile.new(['theme', '.yml'])
      theme_file.write("font:\n  color: red\n")
      theme_file.flush

      ps = Przn::Parser.parse(File.read(deck.path))
      c = Przn::Controller.new(ps, @term, @renderer,
                                source_file: deck.path, theme_path: theme_file.path)

      theme_file.rewind
      theme_file.truncate(0)
      theme_file.write("font:\n  color: green\n")
      theme_file.flush

      c.send(:reload)
      assert_equal 'green', @renderer.theme.font[:color]
    ensure
      deck&.close!
      theme_file&.close!
    end

    test 'auto-discovers theme.yml next to the deck when no explicit theme_path' do
      Dir.mktmpdir do |dir|
        deck_path  = File.join(dir, 'deck.md')
        theme_path = File.join(dir, 'theme.yml')
        File.write(deck_path, "# A\n")

        ps = Przn::Parser.parse(File.read(deck_path))
        c = Przn::Controller.new(ps, @term, @renderer, source_file: deck_path)

        # Drop in a theme.yml mid-session; the next reload should pick it up.
        File.write(theme_path, "font:\n  color: cyan\n")
        c.send(:reload)
        assert_equal 'cyan', @renderer.theme.font[:color]
      end
    end

    test 'falls back to Theme.default when no theme.yml is discoverable' do
      Dir.mktmpdir do |dir|
        deck_path = File.join(dir, 'deck.md')
        File.write(deck_path, "# A\n")

        ps = Przn::Parser.parse(File.read(deck_path))
        c = Przn::Controller.new(ps, @term, @renderer, source_file: deck_path)

        c.send(:reload)
        # The theme must not be nil — apply_slide_background would crash
        # on the next render otherwise. The default theme has a
        # background hash (possibly empty) so the call to `.background`
        # downstream stays safe.
        assert_not_nil @renderer.theme
        assert_not_nil @renderer.theme.background
      end
    end

    test 'silently no-ops when source_file is nil' do
      ps = Przn::Parser.parse("# A\n")
      c = Przn::Controller.new(ps, @term, @renderer)  # no source_file
      assert_nothing_raised { c.send(:reload) }
      assert_equal 0, @renderer.renders
    end

    test 'swallows IO errors so a missing / unreadable file does not crash the session' do
      ps = Przn::Parser.parse("# A\n")
      c = Przn::Controller.new(ps, @term, @renderer,
                                source_file: '/nonexistent/path/to/deck.md')
      assert_nothing_raised { c.send(:reload) }
      assert_equal 0, @renderer.renders
    end
  end
end
