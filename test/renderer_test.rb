# frozen_string_literal: true

require "test_helper"
require "tempfile"

class RendererTest < Test::Unit::TestCase
  def setup
    @renderer = Przn::Renderer.new(nil)
  end

  # Helper: invoke the private wrap_segments
  def wrap(segments, max_width, para_scale = Przn::Renderer::DEFAULT_SCALE)
    @renderer.send(:wrap_segments, segments, max_width, para_scale)
  end

  # Helper: total rendered cells of one wrapped line, given para_scale
  def line_cells(line, para_scale)
    line.sum { |seg|
      content = seg[1] || ""
      s = seg[0] == :tag ? (Przn::Parser::SIZE_SCALES[seg[2]] || para_scale) : para_scale
      @renderer.send(:display_width, content) * s
    }
  end

  sub_test_case "wrap_segments" do
    test "returns single line when content fits" do
      segments = [[:text, "hello"]]
      lines = wrap(segments, 10, 2)
      assert_equal 1, lines.size
      assert_equal segments, lines[0]
    end

    test "wraps a long text segment across lines" do
      # max_width = 3 units at scale 2 = 6 cells, "abcdefgh" needs 16 cells -> 3 lines
      segments = [[:text, "abcdefgh"]]
      lines = wrap(segments, 3, 2)
      assert_equal 3, lines.size
      assert_equal "abc", lines[0][0][1]
      assert_equal "def", lines[1][0][1]
      assert_equal "gh",  lines[2][0][1]
    end

    test "no line exceeds the cell budget for a uniform-scale paragraph" do
      segments = [[:text, "the quick brown fox jumps over the lazy dog"]]
      max_width = 10
      para_scale = 2
      lines = wrap(segments, max_width, para_scale)
      lines.each do |line|
        assert(line_cells(line, para_scale) <= max_width * para_scale,
               "line over budget: #{line.inspect}")
      end
    end

    test "scale-aware: a larger inline tag consumes proportionally more budget" do
      # Paragraph rendered at s=2; an x-large (s=4) span renders each char at 4 cells.
      # Budget = 20 units * 2 cells = 40 cells. "hello " (12) + "WORLD" (20) + " aft" (8) = 40,
      # so " after"'s last 2 chars must wrap to a second line.
      segments = [
        [:text, "hello "],
        [:tag, "WORLD", "x-large"],
        [:text, " after"],
      ]
      lines = wrap(segments, 20, 2)
      assert_equal 2, lines.size
      assert_equal 40, line_cells(lines[0], 2)
      assert_equal "er", lines[1].last[1]
    end

    test "no line exceeds budget when scales are mixed" do
      segments = [
        [:text, "abc "],
        [:tag, "BIG", "x-large"],     # s=4
        [:text, " mid "],
        [:tag, "small-ish", "small"], # s=2 (== para_scale)
        [:text, " end of paragraph"],
      ]
      max_width = 12
      para_scale = 2
      lines = wrap(segments, max_width, para_scale)
      lines.each do |line|
        assert(line_cells(line, para_scale) <= max_width * para_scale,
               "line over budget: #{line.inspect}")
      end
    end

    test "preserves tag metadata on wrapped chunks" do
      segments = [[:tag, "ABCDEFGH", "x-large"]] # s=4, 8 chars * 4 = 32 cells
      # Budget = 5 units * 2 cells = 10 cells, fits 2 chars per line at s=4
      lines = wrap(segments, 5, 2)
      lines.each do |line|
        assert_equal :tag, line[0][0]
        assert_equal "x-large", line[0][2]
      end
      assert_equal "ABCDEFGH", lines.map { |l| l[0][1] }.join
    end

    test "returns segments unchanged when max_width is non-positive" do
      segments = [[:text, "anything"]]
      assert_equal [segments], wrap(segments, 0, 2)
      assert_equal [segments], wrap(segments, -1, 2)
    end

    test "skips empty content segments without crashing" do
      segments = [[:text, ""], [:text, "ok"]]
      lines = wrap(segments, 10, 2)
      assert_equal 1, lines.size
      assert_equal "ok", lines[0].last[1]
    end

    test "honors emoji as 2-cell wide (so list bullets like 🍕 don't make wrap budget overflow)" do
      assert_equal 2, @renderer.send(:display_width, "🍕")
      assert_equal 2, @renderer.send(:display_width, "🎯")
      assert_equal 2, @renderer.send(:display_width, "🚀")
    end

    test "honors CJK double-width characters in cell counting" do
      # CJK char display_width = 2; at para_scale=2 each takes 4 cells.
      # Budget = 4 units * 2 = 8 cells = 2 CJK chars per line.
      segments = [[:text, "あいうえお"]]
      lines = wrap(segments, 4, 2)
      lines.each do |line|
        assert(line_cells(line, 2) <= 8, "line over budget: #{line.inspect}")
      end
      assert_equal "あいうえお", lines.map { |l| l[0][1] }.join
    end
  end

  sub_test_case "split_by_display_width word-awareness" do
    def split(text, max_width)
      @renderer.send(:split_by_display_width, text, max_width)
    end

    test "breaks at the last whitespace, not mid-word" do
      assert_equal ["the quick", "brown fox"], split("the quick brown fox", 9)
    end

    test "drops the whitespace at the break point" do
      chunk, remaining = split("hello world", 8)
      assert_equal "hello", chunk
      assert_equal "world", remaining
    end

    test "breaks at the overflow space when overflow lands on a space" do
      assert_equal ["hello", "world"], split("hello world", 5)
    end

    test "falls back to char-level split when a single word exceeds max_width" do
      assert_equal ["antidise", "stablishment"], split("antidisestablishment", 8)
    end

    test "CJK runs (no whitespace) still split per character" do
      assert_equal ["あいう", "えお"], split("あいうえお", 6)
    end

    test "leading whitespace doesn't produce empty chunks" do
      chunk, remaining = split(" hello", 4)
      assert(!chunk.empty?, "chunk must not be empty: #{chunk.inspect}")
      assert_equal " hel", chunk
      assert_equal "lo", remaining
    end
  end

  sub_test_case "render_segments_scaled font fallback" do
    def render_with_theme(theme, segments, para_scale = 2, **opts)
      r = Przn::Renderer.new(nil, theme: theme)
      r.send(:render_segments_scaled, segments, para_scale, **opts)
    end

    test "body segments pick up theme.font.family as f=" do
      theme = Przn::Theme.new(colors: {}, font: {family: "Helvetica Neue"}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:text, "hi"]])
      assert(out.include?("f=Helvetica Neue"), "expected f= in output: #{out.inspect}")
    end

    test "no f= emitted when neither default_face nor theme.font.family is set" do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:text, "hi"]])
      assert(!out.include?(":f="), "did not expect any f= in output: #{out.inspect}")
    end

    test "explicit default_face beats theme.font.family" do
      theme = Przn::Theme.new(colors: {}, font: {family: "BodyFont"}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:text, "hi"]], default_face: "HeadingFont")
      assert(out.include?("f=HeadingFont"))
      assert(!out.include?("f=BodyFont"))
    end

    test "explicit nil default_face emits no face (no body fallback)" do
      # h1 takes this path when heading_face is unset: it shouldn't silently
      # fall back to theme.font.family, so the title can render in the
      # terminal's default font even when body text is themed.
      theme = Przn::Theme.new(colors: {}, font: {family: "BodyFont"}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:text, "hi"]], default_face: nil)
      assert(!out.include?("f="), "expected no f= when default_face is explicitly nil: #{out.inspect}")
    end

    test "inline <font face=\"...\"> wins over both" do
      theme = Przn::Theme.new(colors: {}, font: {family: "BodyFont"}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:font, "x", {face: "Inline"}]])
      assert(out.include?("f=Inline"))
      assert(!out.include?("f=BodyFont"))
    end

    test "default_h threads through every OSC 66 emit (used by h1 to center proportional fonts)" do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      segments = [[:text, "hi"], [:bold, "yo"], [:font, "x", {face: "Inter"}]]
      out = render_with_theme(theme, segments, default_h: 2)
      assert_equal 3, out.scan(":h=2").size, "expected h=2 on every OSC 66 segment: #{out.inspect}"
    end
  end

  sub_test_case "render_segments_scaled body color (theme.font.color)" do
    def render_with_theme(theme, segments, para_scale = 2)
      Przn::Renderer.new(nil, theme: theme).send(:render_segments_scaled, segments, para_scale)
    end

    test "named font.color wraps the rendered body in the corresponding ANSI code" do
      theme = Przn::Theme.new(colors: {}, font: {color: "red"}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:text, "hi"]])
      assert(out.start_with?("\e[31m"), "expected leading red SGR: #{out.inspect}")
      assert(out.end_with?("\e[0m"), "expected trailing reset: #{out.inspect}")
    end

    test "hex font.color emits a 24-bit ANSI escape" do
      theme = Przn::Theme.new(colors: {}, font: {color: "ff5555"}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:text, "hi"]])
      assert(out.start_with?("\e[38;2;255;85;85m"), "expected 24-bit fg open: #{out.inspect}")
    end

    test "no body color emitted when font.color is unset" do
      theme = Przn::Theme.new(colors: {}, font: {}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:text, "hi"]])
      assert(!out.include?("\e[3"), "did not expect a foreground SGR: #{out.inspect}")
    end

    test "inline color tag overrides body color; body color re-opens after the reset" do
      theme = Przn::Theme.new(colors: {}, font: {color: "white"}, bullet: "・", bullet_size: nil, bg: {}, heading_face: nil)
      out = render_with_theme(theme, [[:text, "a"], [:tag, "B", "red"], [:text, "c"]])
      # white SGR (37) opens, red (31) overrides for the tag, reset+white re-opens after.
      red_idx   = out.index("\e[31m")
      white_idx = out.index("\e[37m")
      assert_not_nil red_idx
      assert_not_nil white_idx
      assert_operator white_idx, :<, red_idx, "body color should open before the inline color: #{out.inspect}"
      assert(out.count("\e[37m") >= 2, "expected body color to re-open after the inline reset: #{out.inspect}")
    end
  end

  sub_test_case "effective_seg_scale" do
    test "returns para_scale for non-tag segments" do
      assert_equal 2, @renderer.send(:effective_seg_scale, [:text, "hi"], 2)
      assert_equal 4, @renderer.send(:effective_seg_scale, [:bold, "hi"], 4)
    end

    test "returns the tag's size scale when known" do
      assert_equal 4, @renderer.send(:effective_seg_scale, [:tag, "x", "x-large"], 2)
      assert_equal 1, @renderer.send(:effective_seg_scale, [:tag, "x", "x-small"], 2)
    end

    test "falls back to para_scale for non-size tags" do
      # named colors are not size scales
      assert_equal 3, @renderer.send(:effective_seg_scale, [:tag, "x", "red"], 3)
    end
  end

  sub_test_case "segments_visible_cells" do
    test "sums cells using each segment's effective scale" do
      segments = [
        [:text, "ab"],                 # 2 chars * 2 = 4
        [:tag, "CDE", "x-large"],      # 3 chars * 4 = 12
        [:bold, "f"],                  # 1 char * 2 = 2
      ]
      assert_equal 18, @renderer.send(:segments_visible_cells, segments, 2)
    end
  end

  sub_test_case "image cache" do
    def setup
      super
      @tmp = Tempfile.new(["renderer_cache_img", ".png"])
      @tmp.write("\x89PNG\r\n\x1a\n")  # not a real PNG, but enough for File.mtime
      @tmp.flush
      @path = @tmp.path
    end

    def teardown
      @tmp.close!
    end

    test "kitty: identical args trigger ImageUtil.kitty_icat once" do
      calls = 0
      Przn::ImageUtil.define_singleton_method(:kitty_icat) do |path, cols:, rows:, x:, y:|
        calls += 1
        "PAYLOAD"
      end
      begin
        a = @renderer.send(:cached_kitty_icat, @path, cols: 10, rows: 5, x: 1, y: 2)
        b = @renderer.send(:cached_kitty_icat, @path, cols: 10, rows: 5, x: 1, y: 2)
        assert_equal "PAYLOAD", a
        assert_equal "PAYLOAD", b
        assert_equal 1, calls
      ensure
        Przn::ImageUtil.singleton_class.remove_method(:kitty_icat)
      end
    end

    test "kitty: different sizing keys produce separate cache entries" do
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

    test "kitty: cache invalidates when file mtime changes" do
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

    test "sixel: identical args trigger ImageUtil.sixel_encode once" do
      calls = 0
      Przn::ImageUtil.define_singleton_method(:sixel_encode) do |path, width:, height:|
        calls += 1
        "SIXEL"
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

  sub_test_case "ensure_kitty_uploaded" do
    class FakeTerm
      attr_reader :writes
      def initialize; @writes = []; end
      def write(s); @writes << s; end
    end

    def setup
      super
      @term = FakeTerm.new
      @renderer = Przn::Renderer.new(@term)
      @tmp = Tempfile.new(["kitty_upload", ".png"])
      @tmp.binmode
      @tmp.write("\x89PNG\r\n\x1a\n".b)
      @tmp.flush
      @path = @tmp.path
    end

    def teardown
      @tmp.close!
    end

    test "uploads on first call and reuses the assigned id on subsequent calls" do
      first  = @renderer.send(:ensure_kitty_uploaded, @path)
      second = @renderer.send(:ensure_kitty_uploaded, @path)
      assert_equal first, second
      assert_equal 1, @term.writes.size
      assert_match(/\A\e_Ga=t,t=f,f=100,i=#{first},q=2;/, @term.writes[0])
    end

    test "re-uploads with a new id when the file mtime changes" do
      first = @renderer.send(:ensure_kitty_uploaded, @path)
      File.utime(Time.now, Time.now + 60, @path)
      second = @renderer.send(:ensure_kitty_uploaded, @path)
      refute_equal first, second
      assert_equal 2, @term.writes.size
    end

    test "assigns distinct ids to distinct files" do
      other = Tempfile.new(["kitty_upload2", ".png"])
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

  sub_test_case "preload" do
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
      @png = Tempfile.new(["preload", ".png"])
      @png.binmode
      @png.write("\x89PNG\r\n\x1a\n".b)
      @png.flush
      @gif = Tempfile.new(["preload", ".gif"])
      @gif.binmode
      @gif.write("GIF89a".b)
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

    test "uploads PNG image blocks and flushes the terminal" do
      slide = slide_with([
        {type: :heading, level: 1, content: "Hi"},
        {type: :image, path: @png.path, attrs: {}},
      ])
      @renderer.preload(slide)
      assert_equal 1, @term.writes.size
      assert_match(/\A\e_Ga=t,t=f,f=100,/, @term.writes[0])
      assert_equal 1, @term.flushes
    end

    test "skips non-PNG image blocks" do
      slide = slide_with([{type: :image, path: @gif.path, attrs: {}}])
      @renderer.preload(slide)
      assert_equal 0, @term.writes.size
    end

    test "skips images that don't exist on disk" do
      slide = slide_with([{type: :image, path: "/nope/missing.png", attrs: {}}])
      @renderer.preload(slide)
      assert_equal 0, @term.writes.size
    end

    test "is a no-op outside Kitty terminals" do
      Przn::ImageUtil.singleton_class.remove_method(:kitty_terminal?)
      Przn::ImageUtil.define_singleton_method(:kitty_terminal?) { false }
      slide = slide_with([{type: :image, path: @png.path, attrs: {}}])
      @renderer.preload(slide)
      assert_equal 0, @term.writes.size
      assert_equal 0, @term.flushes
    end

    test "preload populates the cache so a subsequent ensure_kitty_uploaded is a hit" do
      slide = slide_with([{type: :image, path: @png.path, attrs: {}}])
      @renderer.preload(slide)
      writes_after_preload = @term.writes.size

      id = @renderer.send(:ensure_kitty_uploaded, @png.path)
      assert_equal 1, id
      assert_equal writes_after_preload, @term.writes.size  # no new upload
    end
  end
end
