# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "hexapdf"

class ScreenshotPdfExporterTest < Test::Unit::TestCase
  # Mocks Echoes: when it sees the OSC 7772 `capture <path>` command, it
  # writes a minimal one-page vector PDF to that path so the exporter's
  # wait-for-file loop unblocks and HexaPDF can read it as a real PDF.
  class FakeEchoes
    def self.minimal_pdf_bytes
      doc = HexaPDF::Document.new
      doc.pages.add
      io = StringIO.new
      doc.write(io)
      io.string
    end

    PDF_PAGE = minimal_pdf_bytes.freeze

    attr_reader :captures

    def initialize
      @writes = +""
      @captures = []
    end

    def width;  120; end
    def height; 30;  end
    def cell_pixel_size; [10, 20]; end
    def clear; end
    def hide_cursor; end
    def show_cursor; end
    def enter_alt_screen; end
    def leave_alt_screen; end
    def raw; yield; end
    def move_to(_r, _c); end

    def write(s)
      @writes << s
      flush_capture_requests
    end

    def flush
      flush_capture_requests
    end

    private

    def flush_capture_requests
      while (m = @writes.match(/\e\]7772;capture;([^\a]+)\a/))
        path = m[1]
        File.binwrite(path, PDF_PAGE)
        @captures << path
        @writes = @writes.sub(m[0], "")
      end
    end
  end

  def make_deck(slides_count)
    bodies = (1..slides_count).map { |i| "# Slide #{i}\n\nbody #{i}\n" }
    Przn::Parser.parse(bodies.join("\n"))
  end

  test "captures one PDF per slide and merges them into a multi-page PDF" do
    presentation = make_deck(3)
    fake = FakeEchoes.new
    exporter = Przn::ScreenshotPdfExporter.new(presentation, base_dir: ".", theme: Przn::Theme.default, terminal: fake)

    Tempfile.create(["przn-screenshot", ".pdf"]) do |out|
      exporter.export(out.path)
      assert_equal 3, fake.captures.size
      assert(File.size?(out.path).to_i.positive?, "expected non-empty PDF")
      assert_equal "%PDF", File.binread(out.path, 4)

      merged = HexaPDF::Document.open(out.path)
      assert_equal 3, merged.pages.count, "merged PDF should have one page per slide"
    end
  end

  test "raises when the terminal never produces the requested PDF (capture not implemented)" do
    silent = Object.new
    %i[clear hide_cursor show_cursor enter_alt_screen leave_alt_screen flush].each { |m| silent.define_singleton_method(m) {} }
    silent.define_singleton_method(:write) { |_| }
    silent.define_singleton_method(:move_to) { |_r, _c| }
    silent.define_singleton_method(:width)  { 120 }
    silent.define_singleton_method(:height) { 30 }
    silent.define_singleton_method(:cell_pixel_size) { [10, 20] }

    presentation = make_deck(1)
    exporter = Przn::ScreenshotPdfExporter.new(presentation, base_dir: ".", theme: Przn::Theme.default, terminal: silent)

    # Shrink the timeout so the test doesn't hang for 10s.
    Przn::ScreenshotPdfExporter.send(:remove_const, :CAPTURE_TIMEOUT)
    Przn::ScreenshotPdfExporter.const_set(:CAPTURE_TIMEOUT, 0.2)
    begin
      Tempfile.create(["przn-screenshot", ".pdf"]) do |out|
        assert_raise(RuntimeError) { exporter.export(out.path) }
      end
    ensure
      Przn::ScreenshotPdfExporter.send(:remove_const, :CAPTURE_TIMEOUT)
      Przn::ScreenshotPdfExporter.const_set(:CAPTURE_TIMEOUT, 10)
    end
  end
end
