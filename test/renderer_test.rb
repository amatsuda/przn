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

    test ':break splits the segment stream into separate lines (force <br>)' do
      segments = [[:text, 'one'], [:break], [:text, 'two']]
      lines = wrap(segments, 40, 2)
      assert_equal 2, lines.size
      assert_equal [[:text, 'one']], lines[0]
      assert_equal [[:text, 'two']], lines[1]
    end

    test 'consecutive :break segments produce a blank line between' do
      segments = [[:text, 'a'], [:break], [:break], [:text, 'b']]
      lines = wrap(segments, 40, 2)
      assert_equal 3, lines.size
      assert_equal [[:text, 'a']], lines[0]
      assert_equal [], lines[1]
      assert_equal [[:text, 'b']], lines[2]
    end

    test 'each :break chunk still wraps against max_width independently' do
      long = 'word ' * 20    # ~100 cells when typeset at scale 2 with body_scale
      segments = [[:text, long], [:break], [:text, 'short']]
      lines = wrap(segments, 10, 2)   # very narrow → forces wrap inside chunk 1
      assert_operator lines.size, :>, 2, "expected the long chunk to wrap plus the post-break line"
      assert_equal [[:text, 'short']], lines.last
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

  sub_test_case 'max_inline_scale' do
    def mis(text)
      @renderer.send(:max_inline_scale, text)
    end

    test 'returns nil when no size-bearing markup is present' do
      assert_nil mis('plain words')
      assert_nil mis('with **bold** and `code`')
    end

    test 'detects <size=N> in XML form' do
      assert_equal 5, mis('<size=5>Hello</size>')
      assert_equal 4, mis('plain <size=x-large>X</size> tail')
    end

    test 'detects kramdown {::tag name="N"} form' do
      assert_equal 5, mis('{::tag name="5"}Hi{:/tag}')
    end

    test 'detects <font size="N"> attribute' do
      assert_equal 5, mis('<font size="5">Hi</font>')
      assert_equal 4, mis('<font face="Menlo" size="x-large">code</font>')
    end

    test 'returns the largest size across multiple matches' do
      assert_equal 5, mis('<size=2>a</size> and <size=5>b</size>')
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

    test '<color=HEX> emits the same 24-bit ANSI as <font color="HEX">' do
      tag_segs  = Przn::Parser.parse_inline('<color=ff5555>hi</color>')
      font_segs = Przn::Parser.parse_inline('<font color="ff5555">hi</font>')
      tag_out  = @renderer.send(:render_segments_scaled, tag_segs, 2)
      font_out = @renderer.send(:render_segments_scaled, font_segs, 2)
      assert(tag_out.include?("\e[38;2;255;85;85m"),
             "<color=HEX> should produce a 24-bit SGR: #{tag_out.inspect}")
      assert(font_out.include?("\e[38;2;255;85;85m"),
             "<font color=HEX> should produce a 24-bit SGR: #{font_out.inspect}")
    end

    test '<color=#HEX> (with leading #) renders the same as plain hex' do
      out = @renderer.send(:render_segments_scaled,
                           Przn::Parser.parse_inline('<color=#ff5555>hi</color>'),
                           2)
      assert(out.include?("\e[38;2;255;85;85m"),
             "expected leading # tolerated and resolved: #{out.inspect}")
    end

    test 'bullet.color wraps the rendered bullet in the corresponding ANSI code' do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: {text: '・', color: 'cyan'}, background: {}, title: {})
      out = Przn::Renderer.new(nil, theme: theme).send(:render_bullet, '・')
      assert(out.start_with?("\e[36m"), "expected leading cyan SGR: #{out.inspect}")
      assert(out.end_with?("\e[0m"), "expected trailing reset: #{out.inspect}")
    end

    test 'hex bullet.color emits a 24-bit ANSI escape' do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: {text: '・', color: 'ff5555'}, background: {}, title: {})
      out = Przn::Renderer.new(nil, theme: theme).send(:render_bullet, '・')
      assert(out.start_with?("\e[38;2;255;85;85m"), "expected 24-bit fg open: #{out.inspect}")
    end

    test 'bullet without color is left unwrapped (inherits body color)' do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: {text: '・'}, background: {}, title: {})
      out = Przn::Renderer.new(nil, theme: theme).send(:render_bullet, '・')
      assert(!out.include?("\e[3"), "did not expect a foreground SGR: #{out.inspect}")
      assert(!out.include?("\e[0m"), "did not expect a reset: #{out.inspect}")
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

    test 'font.size sets the body OSC 66 scale (numeric)' do
      theme = Przn::Theme.new(colors: {}, font: {size: 3}, bullet: {text: '・'}, background: {}, title: {})
      assert_equal 3, Przn::Renderer.new(nil, theme: theme).send(:body_scale)
    end

    test 'font.size accepts named sizes via Parser::SIZE_SCALES' do
      theme = Przn::Theme.new(colors: {}, font: {size: 'large'}, bullet: {text: '・'}, background: {}, title: {})
      assert_equal 3, Przn::Renderer.new(nil, theme: theme).send(:body_scale)
    end

    test 'body_scale falls back to DEFAULT_SCALE when font.size is unset' do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: {text: '・'}, background: {}, title: {})
      assert_equal Przn::Renderer::DEFAULT_SCALE,
                   Przn::Renderer.new(nil, theme: theme).send(:body_scale)
    end

    test 'font.size threads into the body render path (paragraph emits s=N)' do
      theme = Przn::Theme.new(colors: {}, font: {size: 3}, bullet: {text: '・'}, background: {}, title: {})
      term = RunnerFakeTerm.new(w: 80, h: 30)
      ps = Przn::Parser.parse("# t\n\nhello world\n")
      Przn::Renderer.new(term, theme: theme).render(ps.slides[0], current: 0, total: 1)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(joined.include?('s=3'), "expected OSC 66 s=3 in body emit: #{joined.inspect}")
      assert(!joined.include?('s=2'),
             "did not expect s=2 anywhere when font.size=3: #{joined.inspect}")
    end

    test 'theme= swaps the active theme (used by the reload key)' do
      theme_a = Przn::Theme.new(colors: {}, font: {color: 'red'},   bullet: {text: '・'}, background: {}, title: {})
      theme_b = Przn::Theme.new(colors: {}, font: {color: 'green'}, bullet: {text: '・'}, background: {}, title: {})
      r = Przn::Renderer.new(nil, theme: theme_a)
      assert(r.send(:render_segments_scaled, [[:text, 'x']], 2).start_with?("\e[31m"))
      r.theme = theme_b
      assert(r.send(:render_segments_scaled, [[:text, 'x']], 2).start_with?("\e[32m"))
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

  sub_test_case 'paragraph: inline size affects only the sized span, not the rest of the line' do
    # Reuse RunnerFakeTerm — same shape as the runner-bar tests.
    class ParaFakeTerm
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

    test '<font size="xx-large"> only scales its own span (`at once` stays s=2)' do
      term = ParaFakeTerm.new(w: 80, h: 30)
      block = {type: :paragraph, content: '<font face="Georgia" size="xx-large" color="cyan">all three</font> at once'}
      Przn::Renderer.new(term).send(:render_paragraph, block, 80, 5)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      # The xx-large span must carry s=5 (the xx-large scale).
      assert_match(/s=5[^;]*;all three/, writes,
                   'expected the <font size="xx-large"> span to be emitted at s=5')
      # The trailing " at once" must NOT carry s=5; it should ride body_scale s=2.
      assert_match(/s=2[^;]*; at once/, writes,
                   'expected " at once" to render at body_scale (s=2), not xx-large')
    end

    test '<size=5>BIG</size> only scales BIG; surrounding text stays at body_scale' do
      term = ParaFakeTerm.new(w: 80, h: 30)
      block = {type: :paragraph, content: 'before <size=5>BIG</size> after'}
      Przn::Renderer.new(term).send(:render_paragraph, block, 80, 5)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert_match(/s=2[^;]*;before /, writes,  'plain "before " should be s=2')
      assert_match(/s=5[^;]*;BIG/,      writes, '"BIG" should be s=5')
      assert_match(/s=2[^;]*; after/,   writes, 'plain " after" should be s=2')
    end

    test 'row advance uses the line max scale so a tall span pushes the next block down' do
      term = ParaFakeTerm.new(w: 80, h: 30)
      block = {type: :paragraph, content: 'tiny <size=5>HUGE</size> rest'}
      new_row = Przn::Renderer.new(term).send(:render_paragraph, block, 80, 5)
      # Single visual line, height = max scale (5) → row advances 5.
      assert_equal 10, new_row, "expected row 5 + 5 = 10, got #{new_row}"
    end

    test 'paragraph without inline size advances by body_scale per line' do
      term = ParaFakeTerm.new(w: 80, h: 30)
      block = {type: :paragraph, content: 'just regular text'}
      new_row = Przn::Renderer.new(term).send(:render_paragraph, block, 80, 5)
      assert_equal 7, new_row, "expected row 5 + body_scale(2) = 7, got #{new_row}"
    end

    test 'unordered list: <size=5>BIG</size> only scales BIG; rest stays s=2' do
      term = ParaFakeTerm.new(w: 80, h: 30)
      block = {type: :unordered_list, items: [{text: 'before <size=5>BIG</size> after', depth: 0}]}
      Przn::Renderer.new(term).send(:render_unordered_list, block, 80, 5)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert_match(/s=2[^;]*;before /, writes)
      assert_match(/s=5[^;]*;BIG/,      writes)
      assert_match(/s=2[^;]*; after/,   writes)
    end

    test 'ordered list: <font size="xx-large"> only scales its own span' do
      term = ParaFakeTerm.new(w: 80, h: 30)
      block = {type: :ordered_list, items: [{text: '<font size="xx-large">big</font> small', depth: 0}]}
      Przn::Renderer.new(term).send(:render_ordered_list, block, 80, 5)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert_match(/s=5[^;]*;big/,    writes)
      assert_match(/s=2[^;]*; small/, writes)
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

    FakeTheme = Struct.new(:counter, :font, :background, :title, :bullet, :colors, :layouts)

    def fake_theme(counter: {duration: '60s'})
      FakeTheme.new(counter, {}, {}, {}, {text: '・'}, {}, {})
    end

    test 'anchors current slide number at column 1' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      r = Przn::Renderer.new(term, theme: fake_theme)
      r.send(:draw_runner_bar, 30, 80, 2, 9, nil)  # slide 3 of 9
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 30, 1], 'expected anchor move at row 30 col 1'
      anchor_write = term.ops.find { |op, s| op == :write && s.is_a?(String) && s.include?('3') }
      assert_not_nil anchor_write, "expected current slide # somewhere: #{term.ops.inspect}"
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

    test 'turtle is absent when counter.duration is nil' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: fake_theme(counter: {}))
        .send(:draw_runner_bar, 30, 80, 4, 9, Time.now - 5)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(!writes.include?('🐢'), "expected no turtle: #{writes.inspect}")
    end

    test 'turtle present when counter.duration is set' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: fake_theme(counter: {duration: '60s'}))
        .send(:draw_runner_bar, 30, 80, 4, 9, Time.now - 30)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(writes.include?('🐢'), "expected turtle in output: #{writes.inspect}")
    end

    test 'draw_runner_bar wipes the emoji track before drawing (no turtle ghosting)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: fake_theme).send(:draw_runner_bar, 30, 80, 4, 9, nil)
      # The first write should be a row-29 wipe (a run of spaces) before
      # any of the anchor-number or emoji emits.
      first_write = term.ops.find { |op, *| op == :write }
      assert_equal :write, first_write[0]
      assert(first_write[1].match?(/\A *\z/), "expected leading wipe of spaces: #{first_write.inspect}")
    end

    test 'redraw_runner_bar is a no-op when counter.duration is unset' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      r = Przn::Renderer.new(term, theme: fake_theme(counter: {}))
      r.redraw_runner_bar(current: 2, total: 9, started_at: Time.now - 1)
      assert_empty term.ops
    end

    test 'redraw_runner_bar emits the wipe + draw when counter.duration is set' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      r = Przn::Renderer.new(term, theme: fake_theme(counter: {duration: '60s'}))
      r.redraw_runner_bar(current: 2, total: 9, started_at: Time.now - 30)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(writes.include?('🐇'), "expected rabbit in redraw: #{writes.inspect}")
      assert(writes.include?('🐢'), "expected turtle in redraw: #{writes.inspect}")
    end

    test 'redraw_runner_bar is a no-op in export mode (PDF capture)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      r = Przn::Renderer.new(term,
                             theme: fake_theme(counter: {duration: '60s'}),
                             export_mode: true)
      r.redraw_runner_bar(current: 2, total: 9, started_at: Time.now - 30)
      assert_empty term.ops
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

    test 'render writes the simple N / M footer when counter.duration is unset' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      renderer = Przn::Renderer.new(term)  # Theme.default: counter is empty
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(joined.include?(' 1 / 9 '), "expected simple footer: #{joined.inspect}")
      assert(!joined.include?('🐇'), "did not expect rabbit emoji: #{joined.inspect}")
    end

    test 'render switches to the runner bar when counter.duration is set' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      renderer = Przn::Renderer.new(term, theme: fake_theme(counter: {duration: '60s'}))
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(joined.include?('🐇'), "expected rabbit in runner bar: #{joined.inspect}")
      assert(!joined.include?(' 1 / 9 '), "did not expect simple N/M footer: #{joined.inspect}")
    end

    test 'counter.color recolors the plain N / M footer' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      theme = fake_theme(counter: {color: 'cyan'})
      renderer = Przn::Renderer.new(term, theme: theme)
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      # cyan SGR is 36
      assert(joined.include?("\e[36m 1 / 9 "), "expected cyan-colored footer: #{joined.inspect}")
      assert(!joined.include?("\e[2m 1 / 9 "), "expected no dim fallback: #{joined.inspect}")
    end

    test 'counter.color recolors the runner-bar anchor numbers' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: fake_theme(counter: {duration: '60s', color: 'ff5555'}))
        .send(:draw_runner_bar, 30, 80, 2, 9, nil)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(writes.include?("\e[38;2;255;85;85m3"), "expected hex-color anchor: #{writes.inspect}")
    end

    test 'plain counter falls back to dim ANSI when counter.color is unset' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      renderer = Przn::Renderer.new(term)  # default theme, no counter color
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(joined.include?("\e[2m 1 / 9 "), "expected dim default: #{joined.inspect}")
    end

    test 'render emits kitty delete-all-placements at the start (Kitty terminals only)' do
      orig = Przn::ImageUtil.method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { true }
      term = RunnerFakeTerm.new(w: 80, h: 30)
      renderer = Przn::Renderer.new(term)
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(joined.include?("\e_Ga=d,d=a,q=2\e\\"),
             "expected delete-all-placements escape: #{joined.inspect}")
    ensure
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?, orig)
    end

    test 'render skips kitty delete-all-placements on non-Kitty terminals' do
      orig = Przn::ImageUtil.method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { false }
      term = RunnerFakeTerm.new(w: 80, h: 30)
      renderer = Przn::Renderer.new(term)
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      refute(joined.include?("\e_Ga=d,d=a"),
             "did not expect delete-all-placements escape: #{joined.inspect}")
    ensure
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?, orig)
    end

    test 'export_mode hides 🐇/🐢 and falls back to the simple N/M counter' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      renderer = Przn::Renderer.new(term,
                                    theme: fake_theme(counter: {duration: '60s'}),
                                    export_mode: true)
      slide = Przn::Slide.new([{type: :blank}])
      renderer.render(slide, current: 0, total: 9)
      joined = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(!joined.include?('🐇'), "expected no rabbit in PDF: #{joined.inspect}")
      assert(!joined.include?('🐢'), "expected no turtle in PDF: #{joined.inspect}")
      assert(joined.include?(' 1 / 9 '), "expected fallback N/M footer: #{joined.inspect}")
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

    test '<br> splits content into multiple rows at the same column' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :at, attrs: {x: '10', y: '5'}, content: 'a<br>b'}
      Przn::Renderer.new(term).send(:render_at, block)
      moves = term.ops.select { |op, *| op == :move_to }
      # body_scale is 2 → second line at y=7, same x.
      assert_includes moves, [:move_to, 5, 10]
      assert_includes moves, [:move_to, 7, 10]
    end

    test '<br> inside <size> inside <at> renders both chunks at the size' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :at, attrs: {x: '10', y: '5'}, content: '<size=3>si<br>ze</size>'}
      Przn::Renderer.new(term).send(:render_at, block)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert(writes.scan(/s=3/).size >= 2,
             "expected both 'si' and 'ze' to be sized at s=3: #{writes.inspect}")
      refute_match(/<br>/, writes, 'no literal <br> should reach the terminal')
    end

    test '<br> inside <font size=1> advances y by 1 (line height follows inline size, not body_scale)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      # body_scale is 2 by default; the second line of a size=1 wrap
      # should land 1 row below the first, not 2.
      block = {type: :at, attrs: {x: '10', y: '5'}, content: '<font size=1>Hello,<br>World!</font>'}
      Przn::Renderer.new(term).send(:render_at, block)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 5, 10], 'first line at the requested y'
      assert_includes moves, [:move_to, 6, 10], 'second line should be 1 row down (size=1), not 2'
    end

    test '<br> inside <size=5> advances y by 5 (line height follows inline size)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :at, attrs: {x: '10', y: '5'}, content: '<size=5>BIG<br>BIG</size>'}
      Przn::Renderer.new(term).send(:render_at, block)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 5, 10],  'first line at the requested y'
      assert_includes moves, [:move_to, 10, 10], 'second BIG line should be 5 rows down'
    end

    test '<br> with no inline size falls back to body_scale advancement' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :at, attrs: {x: '10', y: '5'}, content: 'Hello,<br>World!'}
      Przn::Renderer.new(term).send(:render_at, block)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 5, 10], 'first line at the requested y'
      assert_includes moves, [:move_to, 7, 10], 'no explicit size → body_scale (2)'
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

  end

  sub_test_case 'Slide layouts' do
    class LayoutFakeTerm
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

    def render(md, w: 80, h: 30)
      ps = Przn::Parser.parse(md)
      term = LayoutFakeTerm.new(w: w, h: h)
      Przn::Renderer.new(term, theme: Przn::Theme.default).render(ps.slides[0], current: 0, total: 1)
      term.ops
    end

    test 'route_blocks_to_slots: h1 auto-fills title; left then right by <slot/>' do
      r = Przn::Renderer.new(nil, theme: Przn::Theme.default)
      slots = Przn::Theme.default.layouts['two-column']
      blocks = [
        {type: :heading, level: 1, content: 'T'},
        {type: :paragraph, content: 'left para'},
        {type: :slot, name: nil},
        {type: :paragraph, content: 'right para'},
      ]
      buckets = r.send(:route_blocks_to_slots, blocks, slots)
      assert_equal 1, buckets['title'].size
      assert_equal :heading, buckets['title'][0][:type]
      assert_equal ['left para'], buckets['left'].map { |b| b[:content] }
      assert_equal ['right para'], buckets['right'].map { |b| b[:content] }
    end

    test '<slot name="X"/> jumps to that named slot' do
      r = Przn::Renderer.new(nil, theme: Przn::Theme.default)
      slots = Przn::Theme.default.layouts['two-column']
      blocks = [
        {type: :heading, level: 1, content: 'T'},
        {type: :slot, name: 'right'},
        {type: :paragraph, content: 'right para'},
      ]
      buckets = r.send(:route_blocks_to_slots, blocks, slots)
      assert_equal [], buckets['left']
      assert_equal ['right para'], buckets['right'].map { |b| b[:content] }
    end

    test 'two-column slide renders the right slot at the configured x (>= 50% of 80)' do
      md = "# Two columns {layout=two-column}\n\nleft\n\n<slot/>\n\nright\n"
      ops = render(md, w: 80, h: 30)
      moves = ops.select { |op, *| op == :move_to }
      # Left-slot moves land in the left half; right-slot moves land in the right half.
      left_cols  = moves.map { |_, _, c| c }.select { |c| c <= 36 }
      right_cols = moves.map { |_, _, c| c }.select { |c| c >= 40 && c <= 76 }
      assert(!left_cols.empty?,  "expected at least one move into the left slot: #{moves.inspect}")
      assert(!right_cols.empty?, "expected at least one move into the right slot: #{moves.inspect}")
    end

    test 'a layout-less slide flows through the shipped `default` layout (title band + content)' do
      md = "# Plain title\n\nbody\n"
      ps = Przn::Parser.parse(md)
      term = LayoutFakeTerm.new(w: 80, h: 30)
      # current: 1 so slide 0's auto-cover doesn't kick in.
      Przn::Renderer.new(term, theme: Przn::Theme.default).render(ps.slides[0], current: 1, total: 2)
      moves = term.ops.select { |op, *| op == :move_to }
      # default mirrors title-content: title at y=3 (centered band),
      # content at y=10 (flush-left). Confirm both slots received moves.
      title_move = moves.find { |_, r, _| r == 3 }
      content_move = moves.find { |_, r, _| r >= 10 && r <= 14 }
      assert_not_nil title_move, "expected the title at row 3: #{moves.inspect}"
      assert_not_nil content_move, "expected the body at the content slot (>= row 10): #{moves.inspect}"
    end

    test 'slide 0 without an IAL auto-uses the shipped `cover` layout' do
      md = "# My Presentation\n\nBy Akira, 2026\n"
      ops = render(md, w: 80, h: 30)  # `render` helper passes current: 0
      moves = ops.select { |op, *| op == :move_to }
      # Cover title slot is at y=35% of 30 = row 10. The h1 should land near there.
      title_moves = moves.select { |_, r, _| r >= 8 && r <= 13 }
      # Cover subtitle slot is at y=80% of 30 = row 24. The paragraph follows.
      subtitle_moves = moves.select { |_, r, _| r >= 22 && r <= 26 }
      assert(!title_moves.empty?,
             "expected the h1 to land in the cover title slot near row 10: #{moves.inspect}")
      assert(!subtitle_moves.empty?,
             "expected the paragraph to land in the cover subtitle slot near row 24: #{moves.inspect}")
    end

    test 'slot align: center routes the h1 through compute_pad (and away from flush-left)' do
      # Cover.title has align: center → h1 should land near the middle.
      ops = render("# Centered\n", w: 80, h: 30)
      moves = ops.select { |op, *| op == :move_to }
      title_move = moves.find { |_, r, _| r >= 9 && r <= 13 }
      assert_not_nil title_move, "expected the cover title move: #{moves.inspect}"
      # "Centered" at scale 4 is roughly 32 cells; centered in 80 → pad ~24.
      assert_operator title_move[2], :>, 15,
                      "expected the title's column to be roughly centered, got: #{title_move[2]}"
    end

    test 'slot size: overrides h1 scale (cover.title goes through SIZE_SCALES)' do
      ops = render("# Hi\n", w: 80, h: 30)
      writes = ops.select { |op, *| op == :write }.map { |_, s| s }.join
      # cover.title ships with size: xxx-large → OSC 66 s=6
      assert(writes.include?('s=6'),
             "expected an OSC 66 s=6 emit from xxx-large h1: #{writes.inspect[0, 400]}")
    end

    test 'slot family: cascades into render_segments_scaled :body default' do
      theme = Przn::Theme.default
      original = theme.layouts['default']
      theme.layouts['default'] = [
        Przn::Theme::Slot.new('content', '1', '2', '100%', '100%', nil, nil, 'Menlo', nil)
      ]
      ps = Przn::Parser.parse("a paragraph\n")
      term = LayoutFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: theme).render(ps.slides[0], current: 1, total: 2)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      # OSC 7772 ;multicell carries f= when running under Echoes-aware code.
      # Outside Echoes, the multicell path is suppressed but the slot's family
      # is still threaded into render_segments_scaled. We just confirm the slot
      # didn't crash and produced *some* write.
      assert(!writes.empty?, "expected the paragraph to render")
    ensure
      theme.layouts['default'] = original
    end

    test 'slot color: cascades into body color for paragraphs' do
      theme = Przn::Theme.default
      original = theme.layouts['default']
      theme.layouts['default'] = [
        Przn::Theme::Slot.new('content', '1', '2', '100%', '100%', nil, nil, nil, 'red')
      ]
      ps = Przn::Parser.parse("a paragraph\n")
      term = LayoutFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: theme).render(ps.slides[0], current: 1, total: 2)
      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      # `red` resolves to ANSI fg 31. The paragraph emit should include it.
      assert(writes.include?("\e[31m"),
             "expected ANSI red opener in body writes: #{writes.inspect[0, 200]}")
    ensure
      theme.layouts['default'] = original
    end

    test 'slot align: center centers content WITHIN the slot, not the whole screen' do
      # Define a custom layout: slot positioned at right half of the screen,
      # 30% wide, with align: center. The title should land roughly in the
      # middle of cols 40-63 — not centered on the screen.
      theme = Przn::Theme.default
      original = theme.layouts['default']
      theme.layouts['default'] = [
        Przn::Theme::Slot.new('title', '50%', '5', '30%', '10', :center)
      ]
      ps = Przn::Parser.parse("# Hi\n")
      term = LayoutFakeTerm.new(w: 80, h: 30)
      # current: 1 so the cover auto-pick doesn't override our default.
      Przn::Renderer.new(term, theme: theme).render(ps.slides[0], current: 1, total: 2)
      moves = term.ops.select { |op, *| op == :move_to }
      title_move = moves.find { |_, r, _| r == 5 }
      assert_not_nil title_move, "expected move at row 5: #{moves.inspect}"
      # Slot occupies cols 40-63 (24 wide). "Hi" at scale 4 ≈ 8 cells.
      # Centered: pad = (24-8)/2 = 8, +1 = 9, + @x_offset (40-1=39) = 48.
      assert_operator title_move[2], :>=, 40,
                      "expected the title inside the right-half slot (>= col 40): #{title_move.inspect}"
      assert_operator title_move[2], :<, 64,
                      "expected the title NOT past the slot's right edge: #{title_move.inspect}"
    ensure
      theme.layouts['default'] = original
    end

    test '`default` body content (after the title band) lands flush-left at content_left + 1' do
      md = "# Plain title\n\nbody\n"
      ps = Przn::Parser.parse(md)
      term = LayoutFakeTerm.new(w: 80, h: 30)
      # current: 1 so slide 0's cover auto-pick doesn't fire.
      Przn::Renderer.new(term, theme: Przn::Theme.default).render(ps.slides[0], current: 1, total: 2)
      moves = term.ops.select { |op, *| op == :move_to }
      # `default`'s content slot is at x=5 width=90% (72 cells), no align.
      # content_left(72) = 4, +1 = 5, + @x_offset (5-1=4) → col 9.
      body_move = moves.find { |_, r, _| r >= 10 && r <= 14 }
      assert_not_nil body_move, "expected the body at the content slot (>= row 10): #{moves.inspect}"
      assert_operator body_move[2], :<, 20,
                      "expected default's content slot to be flush-left, got col #{body_move[2]}"
    end

    test 'slide 0 with an explicit {layout=default} skips the cover auto-pick' do
      md = "# My Presentation {layout=default}\n\nbody\n"
      ops = render(md, w: 80, h: 30)
      moves = ops.select { |op, *| op == :move_to }
      # default starts at row 2 — title should appear there, not at y=35%.
      first_body_move = moves.find { |_, r, _| r >= 2 && r <= 6 }
      assert_not_nil first_body_move,
                     "expected an early-row move (default layout), got: #{moves.inspect}"
    end

    test 'when the theme has no `cover` layout, slide 0 falls back to `default`' do
      theme = Przn::Theme.default
      cover = theme.layouts.delete('cover')
      ps = Przn::Parser.parse("# My Presentation\n\nbody\n")
      term = LayoutFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: theme).render(ps.slides[0], current: 0, total: 1)
      moves = term.ops.select { |op, *| op == :move_to }
      first_body_move = moves.find { |_, r, _| r >= 2 && r <= 6 }
      assert_not_nil first_body_move,
                     "expected slide 0 to fall through to default (row 2) when no cover ships"
    ensure
      theme.layouts['cover'] = cover
    end

    test 'overriding layouts.default routes plain slides through that layout' do
      theme = Przn::Theme.default
      original = theme.layouts['default']
      # Alias the `default` slot list to the two-column built-in.
      theme.layouts['default'] = theme.layouts['two-column']
      ps = Przn::Parser.parse("# Plain title\n\nleft\n\n<slot/>\n\nright\n")
      term = LayoutFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: theme).render(ps.slides[0], current: 0, total: 1)
      moves = term.ops.select { |op, *| op == :move_to }
      right_cols = moves.map { |_, _, c| c }.select { |c| c >= 40 && c <= 76 }
      assert(!right_cols.empty?,
             "expected the overridden default to route content into the right slot: #{moves.inspect}")
    ensure
      theme.layouts['default'] = original
    end

    test '{layout=none} on a slide opts out of layouts.default for that slide' do
      theme = Przn::Theme.default
      original = theme.layouts['default']
      # Override `default` to a clearly-different layout so we'd see it if
      # `{layout=none}` accidentally used it.
      theme.layouts['default'] = theme.layouts['two-column']
      ps = Przn::Parser.parse("# Plain title {layout=none}\n\nbody\n")
      term = LayoutFakeTerm.new(w: 80, h: 30)
      Przn::Renderer.new(term, theme: theme).render(ps.slides[0], current: 0, total: 1)
      moves = term.ops.select { |op, *| op == :move_to }
      # No slot offset → all body moves stay in the left half of the screen.
      body_cols = moves.map { |_, _, c| c }.reject { |c| c > 70 }  # exclude footer counter
      assert(body_cols.all? { |c| c < 40 },
             "expected layout=none to skip layouts.default: #{moves.inspect}")
    ensure
      theme.layouts['default'] = original
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

    test 'x and y in cells (Nc suffix) position the image at those 1-based cells and skip flow advance' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'x' => '10c', 'y' => '5c'}}
      new_row = Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 5, 10]
      assert_equal 1, new_row, 'absolute placement must not advance the layout row'
    end

    test 'bare numeric x/y on <img> default to pixels (FakeTerm cell 10x20: x=20px → col 3, y=40px → row 3)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      # cell_w=10 → x=20 px lands inside cell ⌊20/10⌋+1 = 3.
      # cell_h=20 → y=40 px lands inside cell ⌊40/20⌋+1 = 3.
      block = {type: :image, path: @png.path, attrs: {'x' => '20', 'y' => '40'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 3, 3]
    end

    test 'explicit px suffix on <img> matches bare-numeric default' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'x' => '20px', 'y' => '40px'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 3, 3]
    end

    test 'px x/y forward sub-cell offsets to kitty_place X=/Y= for true 1-px positioning' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      captured = {}
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        captured = {x_off: x_off, y_off: y_off}
        'IMG'
      end
      # cell_w=10, cell_h=20. x=23 px → anchor cell ⌊23/10⌋+1 = 3,
      # remainder 23 - 2*10 = 3. y=45 px → cell 3, remainder 5.
      block = {type: :image, path: @png.path, attrs: {'x' => '23', 'y' => '45'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      assert_equal({x_off: 3, y_off: 5}, captured,
                   'sub-cell pixel remainder should land in kitty_place X=/Y=')
    end

    test 'cell-form x/y carry no sub-cell offset (X=/Y= not emitted)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      captured = {}
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        captured = {x_off: x_off, y_off: y_off}
        'IMG'
      end
      block = {type: :image, path: @png.path, attrs: {'x' => '5c', 'y' => '3c'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      assert_equal({x_off: 0, y_off: 0}, captured,
                   'cell-form coords already land on a cell edge; sub-cell offset must be 0')
    end

    test 'positioned image (both x and y) defaults to z=-1 so text layers on top' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      # Stub kitty_place to record the z arg.
      captured_z = nil
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        captured_z = z
        'IMG'
      end

      block = {type: :image, path: @png.path, attrs: {'x' => '10', 'y' => '5'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      assert_equal(-1, captured_z,
                   'a pinned <img x y> should land at z=-1 so the cells the placement covers stay readable when text writes restore them in the pre-pass flow')
    end

    test 'flow image stays at the default Kitty z (no z= sent)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      captured_z = :unset
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        captured_z = z
        'IMG'
      end
      block = {type: :image, path: @png.path, attrs: {}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 5)
      assert_nil captured_z, 'flow images should not pass a z= so Echoes uses its default (0, on top)'
    end

    test 'explicit z="N" on <img> wins over the positioned-default of z=-1' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      captured_z = nil
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        captured_z = z
        'IMG'
      end
      block = {type: :image, path: @png.path, attrs: {'x' => '10', 'y' => '5', 'z' => '2'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      assert_equal 2, captured_z, 'explicit z="2" should override the positioned default of -1'
    end

    test 'positioned image placement precedes prior text writes (pre-pass)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      # The sub_test_case setup stubs kitty_place → 'IMG'. The pre-pass
      # should emit that sentinel BEFORE any of the slide's text writes.
      md = "# t\n- before\n<img src=\"#{@png.path}\" x=\"10\" y=\"5\" />\n- after\n"
      ENV['TERM_PROGRAM'] = 'Echoes'
      ps = Przn::Parser.parse(md)
      Przn::Renderer.new(term).render(ps.slides[0], current: 0, total: 1)

      image_idx = term.ops.find_index { |op, s| op == :write && s == 'IMG' }
      before_idx = term.ops.find_index { |op, s| op == :write && s.is_a?(String) && s.include?('before') }
      assert_not_nil image_idx, 'image placement (IMG) must be emitted'
      assert_not_nil before_idx, '"before" text must be emitted'
      assert_operator image_idx, :<, before_idx,
                      'positioned image must place before prior text writes ' \
                      "(image at op #{image_idx}, 'before' at op #{before_idx})"
    end

    test 'percent x/y resolve against terminal width / height' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'x' => '50%', 'y' => '50%'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      moves = term.ops.select { |op, *| op == :move_to }
      assert_includes moves, [:move_to, 15, 40]
    end

    test 'x only (cells): pins horizontal, uses flow row for vertical, skips flow advance' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'x' => '10c'}}
      new_row = Przn::Renderer.new(term).send(:render_image, block, 80, 7)
      moves = term.ops.select { |op, *| op == :move_to }
      # y stays at the incoming flow row (7); x lands at the requested cell.
      assert_includes moves, [:move_to, 7, 10]
      assert_equal 7, new_row, 'x-only positioning should not advance the flow row'
    end

    test 'y only (cells): pins vertical, uses centered flow column for horizontal, skips flow advance' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'y' => '12c'}}
      new_row = Przn::Renderer.new(term).send(:render_image, block, 80, 5)
      moves = term.ops.select { |op, *| op == :move_to }
      # 200×200 px image with cell 10×20 stub → 20 cells wide. Centered
      # in width=80: (80-20)/2 + 1 = 31. y is the explicit 12.
      assert_includes moves, [:move_to, 12, 31]
      assert_equal 5, new_row, 'y-only positioning should not advance the flow row'
    end

    test 'without x and y, image stays horizontally centered and advances the flow' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {}}
      new_row = Przn::Renderer.new(term).send(:render_image, block, 80, 5)
      assert_operator new_row, :>, 5, 'flow-mode image should advance the layout row'
    end

    # The image stub is a 200×200 PNG with cell_pixel_size 10×20.
    # Image cell size: 20 cols × 10 rows. Without any cap the
    # aspect-ratio scaler picks the smaller of available_cols /
    # img_cell_w vs available_rows / img_cell_h. With width="20%" of
    # an 80-cell terminal, the cap = 16 cols, so target_cols ≤ 16
    # (and the image scales vertically to match aspect ratio).
    test 'height="N" (plain integer) is read as a pixel target' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      place_args = nil
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        place_args = {cols: cols, rows: rows}
        ''
      end
      # Stub image is 200×200 with cell_pixel_size [10, 20]. height=100 →
      # scale 100/200 = 0.5 → target_rows = 200/20*0.5 = 5; target_cols = 200/10*0.5 = 10.
      block = {type: :image, path: @png.path, attrs: {'height' => '100'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      assert_equal({cols: 10, rows: 5}, place_args)
    end

    test 'width="Npx" is read as a pixel target (px suffix tolerated)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      place_args = nil
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        place_args = {cols: cols, rows: rows}
        ''
      end
      # width=50px → 50/200 = 0.25 → 5 cols, 2 rows (200/20*0.25).
      block = {type: :image, path: @png.path, attrs: {'width' => '50px'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      assert_equal({cols: 5, rows: 2}, place_args)
    end

    test 'pixel sizing can grow the image past intrinsic' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      place_args = nil
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        place_args = {cols: cols, rows: rows}
        ''
      end
      # height=400 → scale 400/200 = 2.0 → target_rows = 20, target_cols = 40.
      block = {type: :image, path: @png.path, attrs: {'height' => '400'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      assert_equal({cols: 40, rows: 20}, place_args)
    end

    test 'pixel height and width both set: fit-inside (smaller scale wins)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      place_args = nil
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        place_args = {cols: cols, rows: rows}
        ''
      end
      # height=100 → 0.5 ratio. width=200 → 1.0 ratio. min(0.5, 1.0) = 0.5.
      block = {type: :image, path: @png.path, attrs: {'height' => '100', 'width' => '200'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 1)
      assert_equal({cols: 10, rows: 5}, place_args)
    end

    test 'width="N%" caps horizontal extent (relative_width is honored)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      block = {type: :image, path: @png.path, attrs: {'relative_width' => '20'}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 5)
      # The renderer wrote a placement with `c=` indicating the target
      # column count. Pull it out of the kitty_place sentinel.
      place_args = nil
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        place_args = {cols: cols, rows: rows}
        ''
      end
      Przn::Renderer.new(term).send(:render_image, block, 80, 5)
      assert_not_nil place_args
      assert_operator place_args[:cols], :<=, 16,
                      "relative_width=20% should cap cols to 20% of 80 = 16; got #{place_args[:cols]}"
    end

    test 'oversize image renders at intrinsic size (terminal clips the overflow)' do
      # The image stub is 200×200 with cell_pixel 10×20 → 20 cols × 10 rows.
      # On an 8×5 terminal, the image overflows both axes — but with
      # no auto-fit shrink, we still place it at 20×10.
      term = RunnerFakeTerm.new(w: 8, h: 5)
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      place_args = nil
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        place_args = {cols: cols, rows: rows}
        ''
      end
      block = {type: :image, path: @png.path, attrs: {}}
      Przn::Renderer.new(term).send(:render_image, block, 8, 1)
      assert_equal({cols: 20, rows: 10}, place_args,
                   'intrinsic-size placement should overflow the 8×5 terminal')
    end

    test 'on Echoes, JPGs go through the direct kitty-upload path (no kitten icat)' do
      jpg = Tempfile.new(['render', '.jpg'])
      jpg.binmode
      jpg.write("\xFF\xD8\xFF\xE0".b)  # JPEG SOI marker
      jpg.flush

      term = RunnerFakeTerm.new(w: 80, h: 30)
      uploads = 0
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      Przn::ImageUtil.define_singleton_method(:kitty_place) { |**_kw| 'PLACE' }
      Przn::ImageUtil.singleton_class.remove_method(:kitty_upload_png)
      Przn::ImageUtil.define_singleton_method(:kitty_upload_png) do |_path, image_id:|
        uploads += 1
        'UPLOAD'
      end

      prev_term = ENV['TERM_PROGRAM']
      ENV['TERM_PROGRAM'] = 'Echoes'
      begin
        block = {type: :image, path: jpg.path, attrs: {}}
        Przn::Renderer.new(term).send(:render_image, block, 80, 5)
      ensure
        ENV['TERM_PROGRAM'] = prev_term
      end

      writes = term.ops.select { |op, *| op == :write }.map { |_, s| s }.join
      assert_equal 1, uploads, 'expected one direct kitty upload for JPG on Echoes'
      assert(writes.include?('UPLOAD'), 'expected upload sentinel: ' + writes.inspect)
      assert(writes.include?('PLACE'),  'expected place sentinel: ' + writes.inspect)
    ensure
      jpg&.close!
    end

    test 'image with no sizing attrs renders at intrinsic 1.0 scale (not auto-shrunk to fit)' do
      term = RunnerFakeTerm.new(w: 80, h: 30)
      Przn::ImageUtil.singleton_class.remove_method(:kitty_place)
      place_args = nil
      Przn::ImageUtil.define_singleton_method(:kitty_place) do |image_id:, cols:, rows:, z: nil, x_off: 0, y_off: 0|
        place_args = {cols: cols, rows: rows}
        ''
      end
      block = {type: :image, path: @png.path, attrs: {}}
      Przn::Renderer.new(term).send(:render_image, block, 80, 5)
      # Stub: 200×200 px image, cell 10×20 → 20 cols × 10 rows intrinsic.
      assert_equal({cols: 20, rows: 10}, place_args)
    end

    test 'width-only on the markdown form: <img src=... width="20%"/> sets relative_width' do
      slide = Przn::Parser.parse(%(# t\n\n<img src="x.png" width="20%"/>\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal '20', img[:attrs]['relative_width']
    end
  end

  sub_test_case 'render_shape' do
    class ShapeFakeTerm
      attr_reader :ops
      def initialize(w: 80, h: 30); @w, @h, @ops = w, h, []; end
      def width;  @w; end
      def height; @h; end
      def write(s); @ops << [:write, s]; end
      def move_to(r, c); @ops << [:move_to, r, c]; end
      # Anisotropic cell — typical 1:2 wide-to-tall — to verify the
      # renderer composes the SVG in pixel coords (so circles render
      # circular regardless of cell aspect).
      def cell_pixel_size; [10, 20]; end
    end

    def setup
      super
      @orig_kitty = Przn::ImageUtil.method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { true }
    end

    def teardown
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?, @orig_kitty)
    end

    def uploaded_svg(term)
      apc = term.ops.find { |op, s| op == :write && s.is_a?(String) && s.start_with?("\e_Ga=t,t=d") }
      return nil unless apc
      _, payload = apc[1][3..-3].split(';', 2)
      payload.unpack1('m')
    end

    def placement(term)
      term.ops.find { |op, s| op == :write && s.is_a?(String) && s.start_with?("\e_Ga=p") }&.[](1)
    end

    test 'rect: geometry in pixels, viewBox covers the cell-quantized footprint' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :rect,
                              attrs: {'x' => '10', 'y' => '5', 'width' => '20', 'height' => '6', 'fill' => 'red'}})

      svg = uploaded_svg(term)
      # x=10 → (10-1)*cell_w(10) = 90 px. y=5 → 4*20 = 80 px.
      # width=20 → 200 px. height=6 → 120 px. No stroke padding.
      # Quantized: cells 10..29 × 5..10 → viewBox "90 80 200 120".
      assert_match(/viewBox="90 80 200 120"/, svg)
      assert_match(/<rect x="90" y="80" width="200" height="120" fill="#ff0000"\/>/, svg)
      assert_includes term.ops, [:move_to, 5, 10]
      assert_match(/c=20,r=6/, placement(term))
    end

    test 'circle: rx and ry both scale by cell_w → visually circular' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :circle,
                              attrs: {'cx' => '40', 'cy' => '15', 'r' => '5'}})
      svg = uploaded_svg(term)
      # cx=40 → 390 px, cy=15 → 280 px. r=5 → 5*cell_w(10) = 50 px on
      # BOTH axes — circle, not anisotropic ellipse. bbox pixels
      # (340, 230) to (440, 330). Quantized cell footprint:
      # cols floor(340/10)..ceil(440/10) = 34..44 → 10 cols
      # rows floor(230/20)..ceil(330/20) = 11..17 → 6 rows
      # viewBox pixel origin: 34*10=340, 11*20=220. Size: 100, 120.
      assert_match(/viewBox="340 220 100 120"/, svg)
      assert_match(/<circle cx="390" cy="280" r="50" fill="#ffffff"\/>/, svg)
      assert_includes term.ops, [:move_to, 12, 35]
      assert_match(/c=10,r=6/, placement(term))
    end

    test 'ellipse: rx scales by cell_w, ry by cell_h (intentionally anisotropic)' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :ellipse,
                              attrs: {'cx' => '50', 'cy' => '15', 'rx' => '20', 'ry' => '6'}})
      svg = uploaded_svg(term)
      # cx=50→490, cy=15→280, rx=20*10=200, ry=6*20=120.
      assert_match(/<ellipse cx="490" cy="280" rx="200" ry="120"/, svg)
    end

    test 'line: stroke-width in cell-widths, geometry in pixels' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :line,
                              attrs: {'x1' => '10', 'y1' => '5', 'x2' => '70', 'y2' => '5', 'stroke' => 'red'}})
      svg = uploaded_svg(term)
      # x1=10→90, y1=5→80, x2=70→690, y2=5→80. sw default 0.2 cell-widths
      # → 2 px. Pad ±1 px.
      assert_match(/<line x1="90" y1="80" x2="690" y2="80" fill="none" stroke="#ff0000" stroke-width="2"\/>/, svg)
    end

    test 'polyline: points converted to pixels' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :polyline,
                              attrs: {'points' => '10,5 30,15 50,5 70,15', 'stroke' => 'cyan', 'stroke-width' => '0.4'}})
      svg = uploaded_svg(term)
      # Each (col, row) → ((col-1)*10, (row-1)*20).
      # 10,5 → 90,80;  30,15 → 290,280;  50,5 → 490,80;  70,15 → 690,280.
      assert_match(%r{<polyline points="90,80 290,280 490,80 690,280"}, svg)
    end

    test 'polygon: closed-shape default fill = white' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :polygon,
                              attrs: {'points' => '50,2 60,15 40,15'}})
      svg = uploaded_svg(term)
      assert_match(/<polygon points="490,20 590,280 390,280" fill="#ffffff"\/>/, svg)
    end

    test 'arrow: emits both a stem line and a filled triangular head' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      # Horizontal arrow → stem at y=80px; head extends back from (690,80)
      # by head_length = 4*sw_px = 4*0.5*10 = 20px, head_width = 3*sw_px = 15px.
      r.send(:render_shape, {type: :shape, kind: :arrow,
                              attrs: {'x1' => '10', 'y1' => '5', 'x2' => '70', 'y2' => '5',
                                       'stroke' => 'red', 'stroke-width' => '0.5'}})
      svg = uploaded_svg(term)
      # Stem
      assert_match(/<line x1="90" y1="80" x2="690" y2="80" fill="none" stroke="#ff0000" stroke-width="5"\/>/, svg)
      # Head: tip at (690, 80); base at x=670, y=80±7.5.
      assert_match(/<polygon points="690,80 670,87\.500 670,72\.500" fill="#ff0000"\/>/, svg)
    end

    test 'arrow: head fill defaults to stroke color, override-able via fill=' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :arrow,
                              attrs: {'x1' => '10', 'y1' => '5', 'x2' => '70', 'y2' => '5',
                                       'stroke' => 'cyan', 'fill' => 'yellow'}})
      svg = uploaded_svg(term)
      assert_match(/<polygon points="[^"]+" fill="#ffff00"\/>/, svg)
    end

    test 'CSS named colors outside Echoes default set get translated to hex' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :rect,
                              attrs: {'x' => '10', 'y' => '5', 'width' => '20', 'height' => '6', 'fill' => 'tomato'}})
      svg = uploaded_svg(term)
      assert_match(/fill="#ff6347"/, svg, "expected tomato translated: #{svg.inspect}")

      term2 = ShapeFakeTerm.new
      Przn::Renderer.new(term2).send(:render_shape, {type: :shape, kind: :line,
                              attrs: {'x1' => '10', 'y1' => '5', 'x2' => '70', 'y2' => '5', 'stroke' => 'gold'}})
      assert_match(/stroke="#ffd700"/, uploaded_svg(term2))
    end

    test 'hex codes and rgba() pass through unchanged' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :rect,
                              attrs: {'x' => '10', 'y' => '5', 'width' => '20', 'height' => '6', 'fill' => '#ff6347'}})
      assert_match(/fill="#ff6347"/, uploaded_svg(term))

      term2 = ShapeFakeTerm.new
      Przn::Renderer.new(term2).send(:render_shape, {type: :shape, kind: :rect,
                              attrs: {'x' => '10', 'y' => '5', 'width' => '20', 'height' => '6', 'fill' => 'rgba(255,99,71,0.5)'}})
      assert_match(/fill="rgba\(255,99,71,0\.5\)"/, uploaded_svg(term2))
    end

    test '"none" passes through (otherwise unfilled shapes would break)' do
      term = ShapeFakeTerm.new
      Przn::Renderer.new(term).send(:render_shape, {type: :shape, kind: :rect,
                              attrs: {'x' => '10', 'y' => '5', 'width' => '20', 'height' => '6',
                                       'fill' => 'none', 'stroke' => 'gold'}})
      svg = uploaded_svg(term)
      assert_match(/fill="none"/, svg)
      assert_match(/stroke="#ffd700"/, svg)
    end

    test 'arrow: viewBox grows to include the head (vertical arrow extends bbox in x)' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      # Vertical arrow, no horizontal extent on the line, but the head's
      # width forces the bbox to expand horizontally.
      r.send(:render_shape, {type: :shape, kind: :arrow,
                              attrs: {'x1' => '40', 'y1' => '5', 'x2' => '40', 'y2' => '15',
                                       'stroke-width' => '0.5'}})
      placement_str = placement(term)
      # bbox widens to 2 cells (the head extends ±7.5 px horizontally
      # around x=390; even with stroke padding, it stays within
      # cells 38–39). r=12 from 80→280 px + head_length 20 px stem
      # + stroke padding spilling into the next cell.
      assert_match(/c=2,r=12/, placement_str)
    end

    test 'path: M/L coords are rewritten from cells to pixels' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :path,
                              attrs: {'d' => 'M 10 5 L 70 5 Z', 'stroke' => 'red', 'stroke-width' => '0.3'}})
      svg = uploaded_svg(term)
      # (10,5) → ((10-1)*10, (5-1)*20) = (90, 80); (70,5) → (690, 80).
      assert_match(%r{<path d="M 90 80 L 690 80 Z" fill="none" stroke="#ff0000" stroke-width="3"/>}, svg)
    end

    test 'path: relative h/v deltas use scale (no -1 offset)' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :path,
                              attrs: {'d' => 'M 10 10 h 50 v 10 h -50 Z', 'stroke' => 'cyan'}})
      svg = uploaded_svg(term)
      # M 10 10 → (90, 180). h 50 → +500 px. v 10 → +200 px. h -50 → -500 px.
      assert_match(%r{<path d="M 90 180 h 500 v 200 h -500 Z"}, svg)
    end

    test 'path: cubic Bezier control points contribute to bbox' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      # M 10 10 C 30 0 50 0 70 10 — control points at y=0 (above the viewBox-line endpoints)
      r.send(:render_shape, {type: :shape, kind: :path,
                              attrs: {'d' => 'M 10 10 C 30 0 50 0 70 10', 'stroke' => 'lime', 'stroke-width' => '0.3'}})
      svg = uploaded_svg(term)
      # Control points at y=0 → pixel y=-20. bbox stretches up to include them.
      assert_match(%r{viewBox="\d+ -\d+ \d+ \d+"}, svg,
                   "expected negative y in viewBox to include control points: #{svg.inspect}")
    end

    test 'path: returns nil geometry on unknown command (renderer skips)' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :path,
                              attrs: {'d' => 'M 10 5 W 70 5', 'stroke' => 'red'}})  # W isn't valid
      assert_nil uploaded_svg(term)
    end

    test 'percent coords resolve against terminal cells, then convert to pixels' do
      term = ShapeFakeTerm.new   # 80 cols × 30 rows, cell 10×20
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :circle,
                              attrs: {'cx' => '50%', 'cy' => '50%', 'r' => '10%'}})
      svg = uploaded_svg(term)
      # cx=50% of 80 cols = col 40 → (40-1)*10 = 390 px.
      # cy=50% of 30 rows = row 15 → (15-1)*20 = 280 px.
      # r=10% of 80 cols = 8 cells * cell_w(10) = 80 px (uniform).
      assert_match(/<circle cx="390" cy="280" r="80"/, svg)
    end

    test 'missing required attr → silently skip (no upload, no place)' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :rect, attrs: {'x' => '10', 'y' => '5'}})  # no width/height
      assert_nil uploaded_svg(term)
      assert_nil placement(term)
    end

    test 'non-Kitty terminal: no-op' do
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { false }
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :circle,
                              attrs: {'cx' => '40', 'cy' => '15', 'r' => '5'}})
      assert_empty term.ops
    end

    test 'identical shapes on two renders dedup (one upload, two placements)' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      block = {type: :shape, kind: :circle, attrs: {'cx' => '40', 'cy' => '15', 'r' => '5'}}
      r.send(:render_shape, block)
      r.send(:render_shape, block)
      uploads = term.ops.count { |op, s| op == :write && s.is_a?(String) && s.start_with?("\e_Ga=t,t=d") }
      places  = term.ops.count { |op, s| op == :write && s.is_a?(String) && s.start_with?("\e_Ga=p") }
      assert_equal 1, uploads
      assert_equal 2, places
    end

    test 'shape blocks do not advance the flow row (render_block returns row unchanged)' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      block = {type: :shape, kind: :rect, attrs: {'x' => '10', 'y' => '5', 'width' => '20', 'height' => '6'}}
      new_row = r.send(:render_block, block, 80, 12)
      assert_equal 12, new_row
    end

    test 'placement defaults to z=-1 so text drawn at the same cells stays legible' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :rect,
                              attrs: {'x' => '10', 'y' => '5', 'width' => '20', 'height' => '6'}})
      assert_match(/z=-1/, placement(term))
    end

    test 'explicit z="..." attr overrides the default' do
      term = ShapeFakeTerm.new
      r = Przn::Renderer.new(term)
      r.send(:render_shape, {type: :shape, kind: :rect,
                              attrs: {'x' => '10', 'y' => '5', 'width' => '20', 'height' => '6', 'z' => '2'}})
      assert_match(/z=2(?:[^0-9]|\z)/, placement(term))
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

  sub_test_case 'apply_slide_background: image:' do
    class BgFakeTerm
      attr_reader :writes
      def initialize; @writes = []; @move_ops = []; end
      def width;  80; end
      def height; 30; end
      def write(s); @writes << s; end
      def move_to(r, c); @move_ops << [r, c]; end
      attr_reader :move_ops
    end

    def setup
      super
      @png = Tempfile.new(['bg', '.png'])
      @png.binmode
      @png.write("\x89PNG\r\n\x1a\n".b)
      @png.flush

      @orig_kitty = Przn::ImageUtil.method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { true }
    end

    def teardown
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?, @orig_kitty)
      @png.close!
    end

    test 'uploads the bg image and emits a z=-1 full-screen placement' do
      term = BgFakeTerm.new
      r = Przn::Renderer.new(term)
      slide = Struct.new(:blocks, :layout, :attrs).new(
        [{type: :bg, attrs: {image: @png.path}}], nil, {}
      )
      r.send(:apply_slide_background, slide)
      payload = term.writes.join
      assert_match(/\e_Ga=t,t=f,f=100,i=\d+,q=2;/, payload, 'expected an upload sequence')
      assert_match(/\e_Ga=p,i=\d+,c=80,r=30,C=1,q=2,z=-1\e\\/, payload,
                   "expected a z=-1 placement: #{payload.inspect}")
      assert_includes term.move_ops, [1, 1], 'expected the bg placement anchored at (1,1)'
    end

    test 'switching to a slide without a bg-image deletes the previous placement' do
      term = BgFakeTerm.new
      r = Przn::Renderer.new(term)
      slide_with    = Struct.new(:blocks, :layout, :attrs).new(
        [{type: :bg, attrs: {image: @png.path}}], nil, {}
      )
      slide_without = Struct.new(:blocks, :layout, :attrs).new([], nil, {})

      r.send(:apply_slide_background, slide_with)
      uploaded_id = r.instance_variable_get(:@bg_image_id) ||
                    # the placement payload exposes the id; pull from there if needed
                    term.writes.join.match(/a=p,i=(\d+)/)[1].to_i
      r.send(:apply_slide_background, slide_without)
      payload = term.writes.join
      assert_match(/\e_Ga=d,d=i,i=#{uploaded_id},q=2\e\\/, payload,
                   "expected a placement-delete for the previous bg: #{payload.inspect}")
    end

    test 'silently no-ops on non-Kitty terminals (no upload, no placement)' do
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { false }
      term = BgFakeTerm.new
      r = Przn::Renderer.new(term)
      slide = Struct.new(:blocks, :layout, :attrs).new(
        [{type: :bg, attrs: {image: @png.path}}], nil, {}
      )
      r.send(:apply_slide_background, slide)
      payload = term.writes.join
      refute_match(/\e_Ga=t/, payload, "no upload expected: #{payload.inspect}")
      refute_match(/\e_Ga=p/, payload, "no placement expected: #{payload.inspect}")
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

    test 'warms the CodeHighlighter cache so a subsequent highlight is a cache hit' do
      code = "def warmed?\n  true\nend\n"
      slide = slide_with([{type: :code_block, language: 'ruby', content: code}])
      @renderer.preload(slide)

      # Direct call right after preload returns the *same* tokens object
      # — proves the cache hit, not a re-tokenize.
      tokens = Przn::CodeHighlighter.highlight(code, 'ruby')
      again  = Przn::CodeHighlighter.highlight(code, 'ruby')
      assert_same tokens, again
    end

    test 'still warms code blocks even outside Kitty terminals (code highlight is terminal-agnostic)' do
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { false }
      code = "x = 1\n"
      slide = slide_with([{type: :code_block, language: 'ruby', content: code}])
      @renderer.preload(slide)
      a = Przn::CodeHighlighter.highlight(code, 'ruby')
      b = Przn::CodeHighlighter.highlight(code, 'ruby')
      assert_same a, b, 'preload should warm the code cache regardless of terminal'
    end

    test 'skips code blocks with no language (CodeHighlighter would return nil anyway)' do
      slide = slide_with([{type: :code_block, language: nil, content: 'plain text'}])
      # Just shouldn't raise.
      @renderer.preload(slide)
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
