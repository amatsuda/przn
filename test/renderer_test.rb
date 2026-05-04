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
end
