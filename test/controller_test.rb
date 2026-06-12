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
    attr_accessor :theme, :renders, :last_step, :presentation, :render_log
    def initialize; @renders = 0; @last_step = nil; @render_log = []; end
    def render(slide = nil, *, **kwargs)
      @renders += 1
      @last_step = kwargs[:step]
      # Capture opacity-bearing render calls so slide-fade tests can verify
      # the fade lerp. Identifies the slide by the FIRST block's content (or
      # type) since slide objects don't have a stable display name.
      label = slide&.blocks&.first&.then { |b| b[:content] || b[:type] }
      @render_log << {slide: label, opacity: kwargs[:opacity], step: kwargs[:step]}
    end
    def preload(_); end
    # Mirror Renderer#step_count so step-aware navigation logic can be
    # exercised here without dragging the full renderer in.
    def step_count(slide)
      slide.blocks.count { |b| b[:type] == :wait } + 1
    end
    # No animations in controller tests — every step snaps. Mirrors
    # Renderer#max_duration_for_step's "no duration_ms anywhere" return.
    def max_duration_for_step(_slide, _step); 0; end
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

    test 'resets @slide_step to 0 so the reloaded slide starts collapsed' do
      tmp = Tempfile.new(['reload', '.md'])
      tmp.write("# A\n\nfirst\n\n<wait/>\n\nsecond\n")
      tmp.flush
      ps = Przn::Parser.parse(File.read(tmp.path))
      c = Przn::Controller.new(ps, @term, @renderer, source_file: tmp.path)
      c.instance_variable_set(:@slide_step, 1)

      c.send(:reload)
      assert_equal 0, c.instance_variable_get(:@slide_step),
                   'reload must rewind to step 0 — content may have changed'
    ensure
      tmp&.close!
    end
  end

  sub_test_case 'auto-reload: jump_to_change finds the edited slide' do
    def make_controller_at_path(path, current: 0)
      ps = Przn::Parser.parse(File.read(path))
      ps.go_to(current)
      Przn::Controller.new(ps, @term, @renderer, source_file: path)
    end

    test 'jumps to the slide whose source markdown changed' do
      tmp = Tempfile.new(['watched', '.md'])
      tmp.write("# A\n\nfirst\n\n# B\n\nsecond\n\n# C\n\nthird\n")
      tmp.flush

      # Construct controller with the initial source snapshot.
      c = make_controller_at_path(tmp.path, current: 0)
      c.instance_variable_set(:@last_source, File.read(tmp.path))

      # Edit slide B only.
      File.write(tmp.path, "# A\n\nfirst\n\n# B\n\nSECOND edited\n\n# C\n\nthird\n")
      c.send(:reload, jump_to_change: true)

      assert_equal 1, c.instance_variable_get(:@presentation).current,
                   'reload should land on slide B (index 1) — the one that just changed'
    ensure
      tmp&.close!
    end

    test 'jumps to the new slide when one is appended at the end' do
      tmp = Tempfile.new(['watched', '.md'])
      tmp.write("# A\n\nfirst\n\n# B\n\nsecond\n")
      tmp.flush

      c = make_controller_at_path(tmp.path, current: 0)
      c.instance_variable_set(:@last_source, File.read(tmp.path))

      File.write(tmp.path, "# A\n\nfirst\n\n# B\n\nsecond\n\n# C\n\nthird\n")
      c.send(:reload, jump_to_change: true)

      assert_equal 2, c.instance_variable_get(:@presentation).current,
                   'appending a slide should land the cursor on the new last slide'
    ensure
      tmp&.close!
    end

    test 'jump_to_change with no change falls back to current-slide preservation' do
      tmp = Tempfile.new(['watched', '.md'])
      src = "# A\n\nx\n\n# B\n\ny\n"
      tmp.write(src)
      tmp.flush

      c = make_controller_at_path(tmp.path, current: 1)
      c.instance_variable_set(:@last_source, src)

      # Rewrite the same source — no chunk differs.
      File.write(tmp.path, src)
      c.send(:reload, jump_to_change: true)

      assert_equal 1, c.instance_variable_get(:@presentation).current
    ensure
      tmp&.close!
    end

    test 'jump_to_change with no prior snapshot stays on the current slide (first-reload semantics)' do
      tmp = Tempfile.new(['watched', '.md'])
      tmp.write("# A\n\nx\n\n# B\n\ny\n")
      tmp.flush

      c = make_controller_at_path(tmp.path, current: 1)
      # NB: @last_source intentionally unset — emulates the first
      # reload before the watcher has cached any source.

      File.write(tmp.path, "# A\n\nedited!\n\n# B\n\ny\n")
      c.send(:reload, jump_to_change: true)

      assert_equal 1, c.instance_variable_get(:@presentation).current,
                   'without a snapshot to diff against, preserve the current slide'
    ensure
      tmp&.close!
    end
  end

  sub_test_case 'step navigation: <wait/> reveals' do
    def make_controller(markdown)
      ps = Przn::Parser.parse(markdown)
      Przn::Controller.new(ps, @term, @renderer)
    end

    test 'advance walks through steps on the current slide before flipping' do
      md = "# A\n\nfirst\n\n<wait/>\n\nsecond\n\n<wait/>\n\nthird\n\n# B\n\nnext slide\n"
      c = make_controller(md)
      # Step 0 → 1
      c.send(:advance_step_or_slide)
      assert_equal 1, c.instance_variable_get(:@slide_step)
      assert_equal 0, c.instance_variable_get(:@presentation).current
      # Step 1 → 2
      c.send(:advance_step_or_slide)
      assert_equal 2, c.instance_variable_get(:@slide_step)
      assert_equal 0, c.instance_variable_get(:@presentation).current
      # Step 2 is the last on slide A; next advance flips to slide B at step 0.
      c.send(:advance_step_or_slide)
      assert_equal 1, c.instance_variable_get(:@presentation).current
      assert_equal 0, c.instance_variable_get(:@slide_step)
    end

    test 'retreat walks back through steps before flipping to the previous slide' do
      md = "# A\n\nfirst\n\n<wait/>\n\nsecond\n\n# B\n\nb1\n\n<wait/>\n\nb2\n"
      c = make_controller(md)
      c.instance_variable_get(:@presentation).go_to(1)  # on slide B
      c.instance_variable_set(:@slide_step, 1)
      # Retreat within B: 1 → 0
      c.send(:retreat_step_or_slide)
      assert_equal 0, c.instance_variable_get(:@slide_step)
      assert_equal 1, c.instance_variable_get(:@presentation).current
      # Retreat off B: lands on slide A at its LAST step (= 1)
      c.send(:retreat_step_or_slide)
      assert_equal 0, c.instance_variable_get(:@presentation).current
      assert_equal 1, c.instance_variable_get(:@slide_step),
                   'backing into the previous slide should land on its last revealed step'
    end

    test 'render_current threads @slide_step into Renderer#render as step:' do
      c = make_controller("# A\n\nx\n\n<wait/>\n\ny\n")
      c.instance_variable_set(:@slide_step, 1)
      c.send(:render_current)
      assert_equal 1, @renderer.last_step, 'controller must pass @slide_step to render(step:)'
    end

    test 'g (first slide) resets the step counter' do
      md = "# A\n\nx\n\n# B\n\ny\n\n<wait/>\n\nz\n"
      c = make_controller(md)
      c.instance_variable_get(:@presentation).go_to(1)
      c.instance_variable_set(:@slide_step, 1)
      # Simulate the 'g' branch directly — Controller#run's loop dispatches it.
      c.instance_variable_get(:@presentation).first_slide!
      c.instance_variable_set(:@slide_step, 0)
      assert_equal 0, c.instance_variable_get(:@presentation).current
      assert_equal 0, c.instance_variable_get(:@slide_step)
    end
  end

  sub_test_case 'slide-fade transition: {transition=fade}' do
    def setup
      super
      # Sweep theme.transition.duration down to keep the test loops snappy.
      # The controller divides this in half between out + in halves.
      # Enough wall-clock for the 30 fps loop to land 3-4 frames per half
      # without making the test slow.
      @renderer.theme = Struct.new(:transition, :counter)
                              .new({duration: 120}, {})
      @prev_term_program = ENV['TERM_PROGRAM']
      ENV['TERM_PROGRAM'] = 'Echoes'  # gate for the fade path
    end

    def teardown
      ENV['TERM_PROGRAM'] = @prev_term_program
    end

    def make_controller(markdown)
      ps = Przn::Parser.parse(markdown)
      Przn::Controller.new(ps, @term, @renderer)
    end

    def fade_renders_for(label)
      @renderer.render_log.select { |r| r[:slide] == label && r[:opacity] && r[:opacity] < 1.0 }
    end

    test 'outgoing slide with {transition=fade} lerps opacity 1 → 0 before flipping' do
      md = "# OUT {transition=fade}\n\nbody\n\n# IN\n\nbody\n"
      c = make_controller(md)
      c.send(:advance_step_or_slide)

      outgoing = fade_renders_for('OUT')
      assert(outgoing.size >= 2, "expected several fade-out frames on the outgoing slide: #{outgoing.inspect}")
      assert(outgoing.first[:opacity] > outgoing.last[:opacity],
             'fade-out opacity should monotonically decrease (1 → 0)')
      assert_equal 0.0, outgoing.last[:opacity], 'fade-out should land at 0.0'
      assert_equal 1, c.instance_variable_get(:@presentation).current,
                   'presentation must have advanced to the next slide after the fade-out'
    end

    test 'incoming slide with {transition=fade} lerps opacity 0 → 1 after the flip' do
      md = "# OUT\n\nbody\n\n# IN {transition=fade}\n\nbody\n"
      c = make_controller(md)
      c.send(:advance_step_or_slide)

      incoming = fade_renders_for('IN')
      assert(incoming.size >= 2, "expected several fade-in frames on the incoming slide: #{incoming.inspect}")
      assert(incoming.first[:opacity] < incoming.last[:opacity],
             'fade-in opacity should monotonically increase (0 → 1)')
      assert_equal 0.0, incoming.first[:opacity], 'fade-in should start at 0.0'
      assert_equal 1, c.instance_variable_get(:@presentation).current
    end

    test 'mixed: only outgoing has fade — fades out, then snaps in' do
      md = "# OUT {transition=fade}\n\nbody\n\n# IN\n\nbody\n"
      c = make_controller(md)
      c.send(:advance_step_or_slide)
      assert(fade_renders_for('OUT').any?, 'outgoing should have fade frames')
      assert_empty fade_renders_for('IN'), 'incoming without {transition=fade} should not fade in'
    end

    test 'neither slide has {transition=fade}: no fade frames emitted' do
      md = "# OUT\n\nbody\n\n# IN\n\nbody\n"
      c = make_controller(md)
      c.send(:advance_step_or_slide)
      fade_frames = @renderer.render_log.select { |r| r[:opacity] && r[:opacity] < 1.0 }
      assert_empty fade_frames, "no slide opted in; no fade frames expected: #{fade_frames.inspect}"
    end

    test 'non-Echoes terminal snaps even when {transition=fade} is set' do
      ENV['TERM_PROGRAM'] = 'kitty'
      md = "# OUT {transition=fade}\n\nbody\n\n# IN {transition=fade}\n\nbody\n"
      c = make_controller(md)
      c.send(:advance_step_or_slide)
      fade_frames = @renderer.render_log.select { |r| r[:opacity] && r[:opacity] < 1.0 }
      assert_empty fade_frames, "non-Echoes terminal must snap: #{fade_frames.inspect}"
      assert_equal 1, c.instance_variable_get(:@presentation).current
    end

    test 'advance on the LAST slide does not fade (no real slide change)' do
      md = "# OUT\n\nbody\n\n# LAST {transition=fade}\n\nbody\n"
      c = make_controller(md)
      c.instance_variable_get(:@presentation).go_to(1)  # already on last slide
      c.send(:advance_step_or_slide)
      fade_frames = @renderer.render_log.select { |r| r[:opacity] && r[:opacity] < 1.0 }
      assert_empty fade_frames,
                   "no slide change happens at last-slide → press; no fade should run: #{fade_frames.inspect}"
    end

    test 'retreat on slide 0 does not fade (no real slide change)' do
      md = "# FIRST {transition=fade}\n\nbody\n\n# NEXT\n\nbody\n"
      c = make_controller(md)
      # already on slide 0
      c.send(:retreat_step_or_slide)
      fade_frames = @renderer.render_log.select { |r| r[:opacity] && r[:opacity] < 1.0 }
      assert_empty fade_frames,
                   "no slide change happens at slide-0 ← press; no fade should run: #{fade_frames.inspect}"
    end

    test 'retreat with {transition=fade} also fades in both directions' do
      md = "# DESTINATION {transition=fade}\n\nbody\n\n# LEAVING {transition=fade}\n\nbody\n"
      c = make_controller(md)
      c.instance_variable_get(:@presentation).go_to(1)
      c.send(:retreat_step_or_slide)
      assert(fade_renders_for('LEAVING').any?,
             'leaving slide should fade out on backward navigation')
      assert(fade_renders_for('DESTINATION').any?,
             'arriving slide should fade in on backward navigation')
      assert_equal 0, c.instance_variable_get(:@presentation).current
    end
  end
end
