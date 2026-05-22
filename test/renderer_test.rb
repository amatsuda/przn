# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class RendererTest < Test::Unit::TestCase
  def setup
    # Several assertions look for the OSC 7772 ;multicell extension params
    # (`f=`, `flip=`) which `KittyText.sized` only emits inside Echoes.
    # Pin the env here so the suite is deterministic on non-Echoes hosts.
    @prev_term_program = ENV['TERM_PROGRAM']
    ENV['TERM_PROGRAM'] = 'Echoes'
    @renderer = Przn::Renderer.new(nil)
  end

  def teardown
    ENV['TERM_PROGRAM'] = @prev_term_program
  end

  # Helper: invoke the private wrap_segments
  def wrap(segments, max_width, para_scale = Przn::Renderer::DEFAULT_SCALE)
    @renderer.send(:wrap_segments, segments, max_width, para_scale)
  end

  # Helper: total rendered cells of one wrapped line, given para_scale
  def line_cells(line, para_scale)
    line.sum { |seg|
      content = seg[1] || ''
      s = seg[0] == :tag ? (Przn::Parser::SIZE_SCALES[seg[2]] || para_scale) : para_scale
      @renderer.send(:display_width, content) * s
    }
  end

  sub_test_case 'wrap_segments' do
    test 'returns single line when content fits' do
      segments = [[:text, 'hello']]
      lines = wrap(segments, 10, 2)
      assert_equal 1, lines.size
      assert_equal segments, lines[0]
    end

    test 'wraps a long text segment across lines' do
      # max_width = 3 units at scale 2 = 6 cells, "abcdefgh" needs 16 cells -> 3 lines
      segments = [[:text, 'abcdefgh']]
      lines = wrap(segments, 3, 2)
      assert_equal 3, lines.size
      assert_equal 'abc', lines[0][0][1]
      assert_equal 'def', lines[1][0][1]
      assert_equal 'gh',  lines[2][0][1]
    end

    test 'no line exceeds the cell budget for a uniform-scale paragraph' do
      segments = [[:text, 'the quick brown fox jumps over the lazy dog']]
      max_width = 10
      para_scale = 2
      lines = wrap(segments, max_width, para_scale)
      lines.each do |line|
        assert(line_cells(line, para_scale) <= max_width * para_scale,
               "line over budget: #{line.inspect}")
      end
    end

    test 'scale-aware: a larger inline tag consumes proportionally more budget' do
      # Paragraph rendered at s=2; an x-large (s=4) span renders each char at 4 cells.
      # Budget = 20 units * 2 cells = 40 cells. "hello " (12) + "WORLD" (20) + " aft" (8) = 40,
      # so " after"'s last 2 chars must wrap to a second line.
      segments = [
        [:text, 'hello '],
        [:tag, 'WORLD', 'x-large'],
        [:text, ' after']
      ]
      lines = wrap(segments, 20, 2)
      assert_equal 2, lines.size
      assert_equal 40, line_cells(lines[0], 2)
      assert_equal 'er', lines[1].last[1]
    end

    test 'no line exceeds budget when scales are mixed' do
      segments = [
        [:text, 'abc '],
        [:tag, 'BIG', 'x-large'],     # s=4
        [:text, ' mid '],
        [:tag, 'small-ish', 'small'], # s=2 (== para_scale)
        [:text, ' end of paragraph']
      ]
      max_width = 12
      para_scale = 2
      lines = wrap(segments, max_width, para_scale)
      lines.each do |line|
        assert(line_cells(line, para_scale) <= max_width * para_scale,
               "line over budget: #{line.inspect}")
      end
    end

    test 'preserves tag metadata on wrapped chunks' do
      segments = [[:tag, 'ABCDEFGH', 'x-large']] # s=4, 8 chars * 4 = 32 cells
      # Budget = 5 units * 2 cells = 10 cells, fits 2 chars per line at s=4
      lines = wrap(segments, 5, 2)
      lines.each do |line|
        assert_equal :tag, line[0][0]
        assert_equal 'x-large', line[0][2]
      end
      assert_equal 'ABCDEFGH', lines.map { |l| l[0][1] }.join
    end

    test 'returns segments unchanged when max_width is non-positive' do
      segments = [[:text, 'anything']]
      assert_equal [segments], wrap(segments, 0, 2)
      assert_equal [segments], wrap(segments, -1, 2)
    end

    test 'skips empty content segments without crashing' do
      segments = [[:text, ''], [:text, 'ok']]
      lines = wrap(segments, 10, 2)
      assert_equal 1, lines.size
      assert_equal 'ok', lines[0].last[1]
    end

    test "honors emoji as 2-cell wide (so list bullets like 🍕 don't make wrap budget overflow)" do
      assert_equal 2, @renderer.send(:display_width, '🍕')
      assert_equal 2, @renderer.send(:display_width, '🎯')
      assert_equal 2, @renderer.send(:display_width, '🚀')
    end

    test 'honors CJK double-width characters in cell counting' do
      # CJK char display_width = 2; at para_scale=2 each takes 4 cells.
      # Budget = 4 units * 2 = 8 cells = 2 CJK chars per line.
      segments = [[:text, 'あいうえお']]
      lines = wrap(segments, 4, 2)
      lines.each do |line|
        assert(line_cells(line, 2) <= 8, "line over budget: #{line.inspect}")
      end
      assert_equal 'あいうえお', lines.map { |l| l[0][1] }.join
    end
  end

  sub_test_case 'split_by_display_width word-awareness' do
    def split(text, max_width)
      @renderer.send(:split_by_display_width, text, max_width)
    end

    test 'breaks at the last whitespace, not mid-word' do
      assert_equal ['the quick', 'brown fox'], split('the quick brown fox', 9)
    end

    test 'drops the whitespace at the break point' do
      chunk, remaining = split('hello world', 8)
      assert_equal 'hello', chunk
      assert_equal 'world', remaining
    end

    test 'breaks at the overflow space when overflow lands on a space' do
      assert_equal ['hello', 'world'], split('hello world', 5)
    end

    test 'falls back to char-level split when a single word exceeds max_width' do
      assert_equal ['antidise', 'stablishment'], split('antidisestablishment', 8)
    end

    test 'CJK runs (no whitespace) still split per character' do
      assert_equal ['あいう', 'えお'], split('あいうえお', 6)
    end

    test "leading whitespace doesn't produce empty chunks" do
      chunk, remaining = split(' hello', 4)
      assert(!chunk.empty?, "chunk must not be empty: #{chunk.inspect}")
      assert_equal ' hel', chunk
      assert_equal 'lo', remaining
    end
  end

  sub_test_case 'render_segments_scaled font fallback' do
    def render_with_theme(theme, segments, para_scale = 2, **opts)
      r = Przn::Renderer.new(nil, theme: theme)
      r.send(:render_segments_scaled, segments, para_scale, **opts)
    end

    test 'body segments pick up theme.font.family as f=' do
      theme = Przn::Theme.new(colors: {}, font: {family: 'Helvetica Neue'}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:text, 'hi']])
      assert(out.include?('f=Helvetica Neue'), "expected f= in output: #{out.inspect}")
    end

    test 'no f= emitted when neither default_face nor theme.font.family is set' do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:text, 'hi']])
      assert(!out.include?(':f='), "did not expect any f= in output: #{out.inspect}")
    end

    test 'explicit default_face beats theme.font.family' do
      theme = Przn::Theme.new(colors: {}, font: {family: 'BodyFont'}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:text, 'hi']], default_face: 'HeadingFont')
      assert(out.include?('f=HeadingFont'))
      assert(!out.include?('f=BodyFont'))
    end

    test 'explicit nil default_face emits no face (no body fallback)' do
      # h1 takes this path when title.family is unset: it shouldn't silently
      # fall back to theme.font.family, so the title can render in the
      # terminal's default font even when body text is themed.
      theme = Przn::Theme.new(colors: {}, font: {family: 'BodyFont'}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:text, 'hi']], default_face: nil)
      assert(!out.include?('f='), "expected no f= when default_face is explicitly nil: #{out.inspect}")
    end

    test 'inline <font face="..."> wins over both' do
      theme = Przn::Theme.new(colors: {}, font: {family: 'BodyFont'}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:font, 'x', {face: 'Inline'}]])
      assert(out.include?('f=Inline'))
      assert(!out.include?('f=BodyFont'))
    end

    test 'default_h threads through every OSC 66 emit (used by h1 to center proportional fonts)' do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: {text: '・'}, background: {}, title: {})
      segments = [[:text, 'hi'], [:bold, 'yo'], [:font, 'x', {face: 'Inter'}]]
      out = render_with_theme(theme, segments, default_h: 2)
      assert_equal 3, out.scan(':h=2').size, "expected h=2 on every OSC 66 segment: #{out.inspect}"
    end
  end

  sub_test_case 'render_segments_scaled audience mode' do
    test 'strips :note segments when mode is :audience' do
      r = Przn::Renderer.new(nil, mode: :audience)
      out = r.send(:render_segments_scaled, [[:text, 'hi '], [:note, 'secret'], [:text, ' there']], 2)
      assert(!out.include?('secret'), "expected note content stripped: #{out.inspect}")
      assert(out.include?('hi'))
      assert(out.include?('there'))
    end

    test 'renders :note segments dim-inline when mode is :solo (default)' do
      r = Przn::Renderer.new(nil)
      out = r.send(:render_segments_scaled, [[:note, 'side']], 2)
      assert(out.include?('side'), "expected note rendered: #{out.inspect}")
      assert(out.start_with?(Przn::Renderer::ANSI[:dim]))
    end
  end

  sub_test_case 'render_segments_scaled body color (theme.font.color)' do
    def render_with_theme(theme, segments, para_scale = 2)
      Przn::Renderer.new(nil, theme: theme).send(:render_segments_scaled, segments, para_scale)
    end

    test 'named font.color wraps the rendered body in the corresponding ANSI code' do
      theme = Przn::Theme.new(colors: {}, font: {color: 'red'}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:text, 'hi']])
      assert(out.start_with?("\e[31m"), "expected leading red SGR: #{out.inspect}")
      assert(out.end_with?("\e[0m"), "expected trailing reset: #{out.inspect}")
    end

    test 'hex font.color emits a 24-bit ANSI escape' do
      theme = Przn::Theme.new(colors: {}, font: {color: 'ff5555'}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:text, 'hi']])
      assert(out.start_with?("\e[38;2;255;85;85m"), "expected 24-bit fg open: #{out.inspect}")
    end

    test 'no body color emitted when font.color is unset' do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:text, 'hi']])
      assert(!out.include?("\e[3"), "did not expect a foreground SGR: #{out.inspect}")
    end

    test 'inline color tag overrides body color; body color re-opens after the reset' do
      theme = Przn::Theme.new(colors: {}, font: {color: 'white'}, bullet: {text: '・'}, background: {}, title: {})
      out = render_with_theme(theme, [[:text, 'a'], [:tag, 'B', 'red'], [:text, 'c']])
      # white SGR (37) opens, red (31) overrides for the tag, reset+white re-opens after.
      red_idx   = out.index("\e[31m")
      white_idx = out.index("\e[37m")
      assert_not_nil red_idx
      assert_not_nil white_idx
      assert_operator white_idx, :<, red_idx, "body color should open before the inline color: #{out.inspect}"
      assert(out.count("\e[37m") >= 2, "expected body color to re-open after the inline reset: #{out.inspect}")
    end
  end

  sub_test_case 'effective_seg_scale' do
    test 'returns para_scale for non-tag segments' do
      assert_equal 2, @renderer.send(:effective_seg_scale, [:text, 'hi'], 2)
      assert_equal 4, @renderer.send(:effective_seg_scale, [:bold, 'hi'], 4)
    end

    test "returns the tag's size scale when known" do
      assert_equal 4, @renderer.send(:effective_seg_scale, [:tag, 'x', 'x-large'], 2)
      assert_equal 1, @renderer.send(:effective_seg_scale, [:tag, 'x', 'x-small'], 2)
    end

    test 'falls back to para_scale for non-size tags' do
      # named colors are not size scales
      assert_equal 3, @renderer.send(:effective_seg_scale, [:tag, 'x', 'red'], 3)
    end
  end

  sub_test_case 'segments_visible_cells' do
    test "sums cells using each segment's effective scale" do
      segments = [
        [:text, 'ab'],                 # 2 chars * 2 = 4
        [:tag, 'CDE', 'x-large'],      # 3 chars * 4 = 12
        [:bold, 'f']                  # 1 char * 2 = 2
      ]
      assert_equal 18, @renderer.send(:segments_visible_cells, segments, 2)
    end
  end

  sub_test_case 'image cache' do
    def setup
      super
      @tmp = Tempfile.new(['renderer_cache_img', '.png'])
      @tmp.write("\x89PNG\r\n\x1a\n")  # not a real PNG, but enough for File.mtime
      @tmp.flush
      @path = @tmp.path
    end

    def teardown
      @tmp.close!
    end

    test 'kitty: identical args trigger ImageUtil.kitty_icat once' do
      calls = 0
      Przn::ImageUtil.define_singleton_method(:kitty_icat) do |path, cols:, rows:, x:, y:|
        calls += 1
        'PAYLOAD'
      end
      begin
        a = @renderer.send(:cached_kitty_icat, @path, cols: 10, rows: 5, x: 1, y: 2)
        b = @renderer.send(:cached_kitty_icat, @path, cols: 10, rows: 5, x: 1, y: 2)
        assert_equal 'PAYLOAD', a
        assert_equal 'PAYLOAD', b
        assert_equal 1, calls
      ensure
        Przn::ImageUtil.singleton_class.remove_method(:kitty_icat)
      end
    end

    test 'kitty: different sizing keys produce separate cache entries' do
      calls = 0
      Przn::ImageUtil.define_singleton_method(:kitty_icat) do |path, cols:, rows:, x:, y:|
        calls += 1
        "data-#{cols}x#{rows}"
      end
      begin
        @renderer.send(:cached_kitty_icat, @path, cols: 10, rows: 5, x: 0, y: 0)
        @renderer.send(:cached_kitty_icat, @path, cols: 20, rows: 5, x: 0, y: 0)
        @renderer.send(:cached_kitty_icat, @path, cols: 10, rows: 5, x: 0, y: 0) # hit
        assert_equal 2, calls
      ensure
        Przn::ImageUtil.singleton_class.remove_method(:kitty_icat)
      end
    end

    test 'kitty: cache invalidates when file mtime changes' do
      calls = 0
      Przn::ImageUtil.define_singleton_method(:kitty_icat) do |path, cols:, rows:, x:, y:|
        calls += 1
        "v#{calls}"
      end
      begin
        @renderer.send(:cached_kitty_icat, @path, cols: 10, rows: 5, x: 0, y: 0)
        File.utime(Time.now, Time.now + 60, @path)  # bump mtime
        @renderer.send(:cached_kitty_icat, @path, cols: 10, rows: 5, x: 0, y: 0)
        assert_equal 2, calls
      ensure
        Przn::ImageUtil.singleton_class.remove_method(:kitty_icat)
      end
    end

    test 'sixel: identical args trigger ImageUtil.sixel_encode once' do
      calls = 0
      Przn::ImageUtil.define_singleton_method(:sixel_encode) do |path, width:, height:|
        calls += 1
        'SIXEL'
      end
      begin
        @renderer.send(:cached_sixel_encode, @path, width: 100, height: 50)
        @renderer.send(:cached_sixel_encode, @path, width: 100, height: 50)
        assert_equal 1, calls
      ensure
        Przn::ImageUtil.singleton_class.remove_method(:sixel_encode)
      end
    end

    test "caches a nil result so the subprocess isn't re-run on failure" do
      calls = 0
      Przn::ImageUtil.define_singleton_method(:kitty_icat) do |path, **_kw|
        calls += 1
        nil
      end
      begin
        2.times { @renderer.send(:cached_kitty_icat, @path, cols: 1, rows: 1, x: 0, y: 0) }
        assert_equal 1, calls
      ensure
        Przn::ImageUtil.singleton_class.remove_method(:kitty_icat)
      end
    end
  end

  sub_test_case 'draw_runner_bar' do
    class RunnerFakeTerm
      attr_reader :ops
      def initialize(w:, h:); @w, @h, @ops = w, h, []; end
      def width;  @w; end
      def height; @h; end
      def write(s); @ops << [:write, s]; end
      def move_to(r, c); @ops << [:move_to, r, c]; end
      def clear; @ops << [:clear]; end
      def flush; end
      def cell_pixel_size; [10, 20]; end
    end

    FakeTheme = Struct.new(:rabbit, :font, :background, :title, :bullet, :colors)

    def fake_theme(rabbit: {})
      FakeTheme.new(rabbit, {}, {}, {}, {text: '・'}, {})
    end

    test 'anchors current slide number at column 1' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      r = Przn::Renderer.new(term, theme: fake_theme)
      r.send(:draw_runner_bar, 30, 80, 2, 9, nil)  # slide 3 of 9
      first_move = term.ops.find { |op, *| op == :move_to }
      assert_equal [:move_to, 30, 1], first_move
      first_write = term.ops.find { |op, *| op == :write }
      assert(first_write[1].include?('3'),
             "expected current slide # at left: #{term.ops.inspect}")
    end

    test 'anchors total slide count at the right edge' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      r = Przn::Renderer.new(term, theme: fake_theme)
      r.send(:draw_runner_bar, 30, 80, 2, 9, nil)
      # second move should be to (h, w - right.size + 1) where right = "9" (1 char) → col 80
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 30, 80]
    end

    test 'rabbit at far left on first slide; far right on last slide' do
      term1 = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term1, theme: fake_theme).send(:draw_runner_bar, 30, 80, 0, 10, nil)
      rabbit_move_1 = term1.ops.each_cons(2).find { |(_, *), (op, s)| op == :write && s.is_a?(String) && s.include?('🐇') }
      rabbit_col_1 = rabbit_move_1[0][2]

      term2 = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term2, theme: fake_theme).send(:draw_runner_bar, 30, 80, 9, 10, nil)
      rabbit_move_2 = term2.ops.each_cons(2).find { |(_, *), (op, s)| op == :write && s.is_a?(String) && s.include?('🐇') }
      rabbit_col_2 = rabbit_move_2[0][2]

      assert_operator rabbit_col_2, :>, rabbit_col_1,
                      "last-slide rabbit (col #{rabbit_col_2}) should be right of first-slide rabbit (col #{rabbit_col_1})"
    end

    test 'turtle is absent when rabbit.duration is nil' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: fake_theme).send(:draw_runner_bar, 30, 80, 4, 9, Time.now - 5)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(!writes.include?('🐢'), "expected no turtle: #{writes.inspect}")
    end

    test 'turtle present when rabbit.duration is set' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: fake_theme(rabbit: {duration: '60s'}))
        .send(:draw_runner_bar, 30, 80, 4, 9, Time.now - 30)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(writes.include?('🐢'), "expected turtle in output: #{writes.inspect}")
    end

    test 'rabbit emit carries flip=h (via OSC 7772 ;multicell inside Echoes)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: fake_theme).send(:draw_runner_bar, 30, 80, 2, 9, nil)
      rabbit_write = term.ops.find { |op, s| op == :write && s.is_a?(String) && s.include?('🐇') }[1]
      assert(rabbit_write.include?('flip=h'),
             "expected flip=h in rabbit emit: #{rabbit_write.inspect}")
      assert(rabbit_write.include?('7772;multicell'),
             "expected OSC 7772 ;multicell frame (Echoes-private): #{rabbit_write.inspect}")
    end

    test 'render writes the simple N / M footer when theme.rabbit is nil' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      renderer = Przn::Renderer.new(term)  # Theme.default: rabbit is nil
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(joined.include?(' 1 / 9 '), "expected simple footer: #{joined.inspect}")
      assert(!joined.include?('🐇'), "did not expect rabbit emoji: #{joined.inspect}")
    end

    test 'render switches to the runner bar when theme.rabbit is present (even if empty)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      renderer = Przn::Renderer.new(term, theme: fake_theme(rabbit: {}))
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(joined.include?('🐇'), "expected rabbit in runner bar: #{joined.inspect}")
      assert(!joined.include?(' 1 / 9 '), "did not expect simple N/M footer: #{joined.inspect}")
    end
  end

  sub_test_case 'render_at: absolute-position text' do
    test 'moves cursor to (y, x) and writes the inline-parsed content' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :at, attrs: {x: '10', y: '5'}, content: 'hello'}
      Przn::Renderer.new(term).send(:render_at, block)

      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 5, 10]

      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(writes.include?('hello'), "expected content in writes: #{writes.inspect}")
    end

    test 'inner inline markup is honored (size, color, ...)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :at, attrs: {x: '10', y: '5'}, content: '<size=3>BIG</size>'}
      Przn::Renderer.new(term).send(:render_at, block)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(writes.include?('BIG'),  "expected 'BIG' in writes: #{writes.inspect}")
      assert(writes.include?('s=3'),  "expected <size=3> to translate to s=3 in OSC 66: #{writes.inspect}")
    end

    test 'silently skips when x or y is missing or unparseable' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term).send(:render_at, {type: :at, attrs: {y: '5'}, content: 'x'})
      Przn::Renderer.new(term).send(:render_at, {type: :at, attrs: {x: 'huh', y: '5'}, content: 'x'})
      Przn::Renderer.new(term).send(:render_at, {type: :at, attrs: {x: '', y: '5'}, content: 'x'})
      assert_equal [], term.ops, "expected no writes when coords are bad: #{term.ops.inspect}"
    end

    test 'percent coordinates resolve against terminal width / height' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :at, attrs: {x: '50%', y: '50%'}, content: 'mid'}
      Przn::Renderer.new(term).send(:render_at, block)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 15, 40]  # round(0.5 * 30), round(0.5 * 80)
    end

    test 'percent coordinates clamp into the visible area' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term).send(:render_at, {type: :at, attrs: {x: '0%',   y: '0%'},   content: 'a'})
      Przn::Renderer.new(term).send(:render_at, {type: :at, attrs: {x: '100%', y: '100%'}, content: 'b'})
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 1, 1]
      assert_includes moves, [:move_to, 30, 80]
    end

    test 'out-of-range cell coordinates clamp into the visible area' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term).send(:render_at, {type: :at, attrs: {x: '0',   y: '5'},   content: 'a'})
      Przn::Renderer.new(term).send(:render_at, {type: :at, attrs: {x: '999', y: '999'}, content: 'b'})
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 5, 1]      # x=0 clamps to col 1
      assert_includes moves, [:move_to, 30, 80]    # huge values clamp to the right edge
    end

    test 'does not advance the slide layout row (block_height is 0)' do
      r = Przn::Renderer.new(nil)
      assert_equal 0, r.send(:block_height, {type: :at, attrs: {x: '10', y: '5'}, content: 'x'}, 80)
    end
  end

  sub_test_case 'render_image: x/y absolute positioning' do
    def setup
      @png = Tempfile.new(['render_img_xy', '.png'])
      @png.binmode
      @png.write("\x89PNG\r\n\x1a\n".b)
      @png.flush

      # Pretend the file is a 200x200 PNG on a kitty-graphics terminal,
      # so render_image takes the kitty-place path instead of skipping.
      @stubs = {
        kitty_terminal?: Przn::ImageUtil.method(:kitty_terminal?),
        png?:            Przn::ImageUtil.method(:png?),
        image_size:      Przn::ImageUtil.method(:image_size),
        kitty_place:     Przn::ImageUtil.method(:kitty_place),
      }
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { true }
      Przn::ImageUtil.define_singleton_method(:png?) { |_p| true }
      Przn::ImageUtil.define_singleton_method(:image_size) { |_p| [200, 200] }
      Przn::ImageUtil.define_singleton_method(:kitty_place) { |**_kw| 'IMG' }
    end

    def teardown
      @stubs.each do |name, orig|
        Przn::ImageUtil.singleton_class.remove_method(name)
        Przn::ImageUtil.define_singleton_method(name, orig)
      end
      @png.close!
    end

    test 'x and y position the image at those 1-based cells and skip flow advance' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'x' => '10', 'y' => '5'}}
      new_row = Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 5, 10]
      assert_equal 1, new_row, 'absolute placement must not advance the layout row'
    end

    test 'percent x/y resolve against terminal width / height' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'x' => '50%', 'y' => '50%'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 15, 40]
    end

    test 'block_height is 0 when x and y are set (layered, not in flow)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'x' => '10', 'y' => '5'}}
      assert_equal 0, Przn::Renderer.new(term).send(:block_height, block, 80)
    end

    test 'without x and y, image stays horizontally centered and advances the flow' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {}}
      new_row = Przn::Renderer.new(term).send(:render_image, block, 80, 5)
      assert_operator new_row, :>, 5, 'flow-mode image should advance the layout row'
    end
  end

  sub_test_case 'ensure_kitty_uploaded' do
    class FakeTerm
      attr_reader :writes
      def initialize; @writes = []; end
      def write(s); @writes << s; end
    end

    def setup
      super
      @term = FakeTerm.new
      @renderer = Przn::Renderer.new(@term)
      @tmp = Tempfile.new(['kitty_upload', '.png'])
      @tmp.binmode
      @tmp.write("\x89PNG\r\n\x1a\n".b)
      @tmp.flush
      @path = @tmp.path
    end

    def teardown
      @tmp.close!
    end

    test 'uploads on first call and reuses the assigned id on subsequent calls' do
      first  = @renderer.send(:ensure_kitty_uploaded, @path)
      second = @renderer.send(:ensure_kitty_uploaded, @path)
      assert_equal first, second
      assert_equal 1, @term.writes.size
      assert_match(/\A\e_Ga=t,t=f,f=100,i=#{first},q=2;/, @term.writes[0])
    end

    test 're-uploads with a new id when the file mtime changes' do
      first = @renderer.send(:ensure_kitty_uploaded, @path)
      File.utime(Time.now, Time.now + 60, @path)
      second = @renderer.send(:ensure_kitty_uploaded, @path)
      refute_equal first, second
      assert_equal 2, @term.writes.size
    end

    test 'assigns distinct ids to distinct files' do
      other = Tempfile.new(['kitty_upload2', '.png'])
      other.binmode
      other.write("\x89PNG\r\n\x1a\n".b)
      other.flush

      a = @renderer.send(:ensure_kitty_uploaded, @path)
      b = @renderer.send(:ensure_kitty_uploaded, other.path)
      refute_equal a, b
      assert_equal 2, @term.writes.size
    ensure
      other&.close!
    end
  end

  sub_test_case 'preload' do
    class FakeTerm2
      attr_reader :writes, :flushes
      def initialize; @writes = []; @flushes = 0; end
      def write(s); @writes << s; end
      def flush; @flushes += 1; end
    end

    def setup
      super
      @term = FakeTerm2.new
      @renderer = Przn::Renderer.new(@term)
      @png = Tempfile.new(['preload', '.png'])
      @png.binmode
      @png.write("\x89PNG\r\n\x1a\n".b)
      @png.flush
      @gif = Tempfile.new(['preload', '.gif'])
      @gif.binmode
      @gif.write('GIF89a'.b)
      @gif.flush

      # Force kitty terminal detection
      @orig_kitty = Przn::ImageUtil.method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { true }
    end

    def teardown
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?, @orig_kitty)
      @png.close!
      @gif.close!
    end

    def slide_with(blocks)
      Struct.new(:blocks).new(blocks)
    end

    test 'uploads PNG image blocks and flushes the terminal' do
      slide = slide_with([
        {type: :heading, level: 1, content: 'Hi'},
        {type: :image, path: @png.path, attrs: {}}
      ])
      @renderer.preload(slide)
      assert_equal 1, @term.writes.size
      assert_match(/\A\e_Ga=t,t=f,f=100,/, @term.writes[0])
      assert_equal 1, @term.flushes
    end

    test 'skips non-PNG image blocks' do
      slide = slide_with([{type: :image, path: @gif.path, attrs: {}}])
      @renderer.preload(slide)
      assert_equal 0, @term.writes.size
    end

    test "skips images that don't exist on disk" do
      slide = slide_with([{type: :image, path: '/nope/missing.png', attrs: {}}])
      @renderer.preload(slide)
      assert_equal 0, @term.writes.size
    end

    test 'is a no-op outside Kitty terminals' do
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { false }
      slide = slide_with([{type: :image, path: @png.path, attrs: {}}])
      @renderer.preload(slide)
      assert_equal 0, @term.writes.size
      assert_equal 0, @term.flushes
    end

    test 'preload populates the cache so a subsequent ensure_kitty_uploaded is a hit' do
      slide = slide_with([{type: :image, path: @png.path, attrs: {}}])
      @renderer.preload(slide)
      writes_after_preload = @term.writes.size

      id = @renderer.send(:ensure_kitty_uploaded, @png.path)
      assert_equal 1, id
      assert_equal writes_after_preload, @term.writes.size  # no new upload
    end
  end
end
