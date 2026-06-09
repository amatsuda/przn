# frozen_string_literal: true

require 'test_helper'
require 'tempfile'
require 'hexapdf'
require_relative '../lib/przn/screenshot_pdf_exporter'

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
      @writes = +''
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
        @writes = @writes.sub(m[0], '')
      end
    end
  end

  def make_deck(slides_count)
    bodies = (1..slides_count).map { |i| "# Slide #{i}\n\nbody #{i}\n" }
    Przn::Parser.parse(bodies.join("\n"))
  end

  def setup
    # The merge_pdfs post-process opportunistically shells out to
    # Ghostscript for lossy recompression; opt out across the test
    # suite so runs stay self-contained and the install hint doesn't
    # spam stderr.
    @prev_gs = ENV['PRZN_GS']
    ENV['PRZN_GS'] = ''
  end

  def teardown
    ENV['PRZN_GS'] = @prev_gs
  end

  test 'renders content past <wait/> on each captured page' do
    # Each page should show the slide's FINAL reveal state — a PDF is a
    # static artifact, so an exported deck must include everything that
    # `<wait/>` walks the audience through.
    presentation = Przn::Parser.parse("# cover\n\n# title\nfoo\n<wait />\nbar\n")
    fake = FakeEchoes.new
    # Capture the raw bytes the renderer sends. The hidden block past
    # `<wait/>` is gated by the renderer's `step:` arg — if step==0,
    # "bar" never reaches the terminal.
    seen = +''
    fake.singleton_class.prepend(Module.new do
      define_method(:write) { |s| seen << s; super(s) }
    end)
    exporter = Przn::ScreenshotPdfExporter.new(presentation, base_dir: '.',
                                                theme: Przn::Theme.default, terminal: fake)

    Tempfile.create(['przn-wait', '.pdf']) do |out|
      exporter.export(out.path)
      assert_includes seen, 'bar',
                      'the post-<wait/> body must be emitted to the terminal during export'
    end
  end

  test 'captures one PDF per slide and merges them into a multi-page PDF' do
    presentation = make_deck(3)
    fake = FakeEchoes.new
    exporter = Przn::ScreenshotPdfExporter.new(presentation, base_dir: '.', theme: Przn::Theme.default, terminal: fake)

    Tempfile.create(['przn-screenshot', '.pdf']) do |out|
      exporter.export(out.path)
      assert_equal 3, fake.captures.size
      assert(File.size?(out.path).to_i.positive?, 'expected non-empty PDF')
      assert_equal '%PDF', File.binread(out.path, 4)

      merged = HexaPDF::Document.open(out.path)
      assert_equal 3, merged.pages.count, 'merged PDF should have one page per slide'
    end
  end

  # ---------------------------------------------------------------------
  # Post-merge optimization passes
  # ---------------------------------------------------------------------

  def add_image_xobject(doc, stream:, filter: nil, width: 4, height: 4)
    dict = {Type: :XObject, Subtype: :Image,
            Width: width, Height: height,
            BitsPerComponent: 8, ColorSpace: :DeviceGray}
    dict[:Filter] = filter if filter
    img = doc.add(dict, stream: stream)
    img.must_be_indirect = true
    img
  end

  def attach_image_to_page(doc, page, img, name: :Im1)
    page[:Resources] ||= doc.wrap({})
    page[:Resources][:XObject] ||= doc.wrap({})
    page[:Resources][:XObject][name] = img
  end

  def new_exporter
    Przn::ScreenshotPdfExporter.new(make_deck(1), base_dir: '.',
                                     theme: Przn::Theme.default, terminal: FakeEchoes.new)
  end

  test 'dedup_image_xobjects collapses pages sharing the same image bytes' do
    doc = HexaPDF::Document.new
    raw = 'identical-pixels' * 256  # 4 KB sample stream
    p1 = doc.pages.add
    p2 = doc.pages.add
    img1 = add_image_xobject(doc, stream: raw)
    img2 = add_image_xobject(doc, stream: raw.dup)
    attach_image_to_page(doc, p1, img1, name: :A)
    attach_image_to_page(doc, p2, img2, name: :B)

    new_exporter.send(:dedup_image_xobjects, doc)

    # p1 and p2 should now reference the same underlying object.
    ref1 = p1[:Resources][:XObject][:A]
    ref2 = p2[:Resources][:XObject][:B]
    assert_equal ref1.oid, ref2.oid,
                 'identical-stream image XObjects should collapse to one shared ref'
  end

  test 'dedup_image_xobjects leaves distinct images alone' do
    doc = HexaPDF::Document.new
    p1 = doc.pages.add
    p2 = doc.pages.add
    a = add_image_xobject(doc, stream: 'aaaa' * 256)
    b = add_image_xobject(doc, stream: 'bbbb' * 256)
    attach_image_to_page(doc, p1, a, name: :A)
    attach_image_to_page(doc, p2, b, name: :B)

    new_exporter.send(:dedup_image_xobjects, doc)

    refute_equal p1[:Resources][:XObject][:A].oid,
                 p2[:Resources][:XObject][:B].oid,
                 'images with different stream bytes must NOT be deduped'
  end

  test 'reflate_uncompressed_images shrinks and tags Filter=FlateDecode' do
    doc = HexaPDF::Document.new
    page = doc.pages.add
    # Highly compressible payload — zeros run through Flate easily.
    raw = "\x00" * 4096
    img = add_image_xobject(doc, stream: raw)
    attach_image_to_page(doc, page, img)

    new_exporter.send(:reflate_uncompressed_images, doc)

    assert_equal :FlateDecode, img[:Filter],
                 'an unfiltered image stream should pick up Filter=FlateDecode'
    assert_operator img.stream.to_s.bytesize, :<, raw.bytesize,
                    'Flate compression of 4 KB of zeros must shrink the stream'
  end

  test 'reflate_uncompressed_images leaves DCT (JPEG) streams untouched' do
    doc = HexaPDF::Document.new
    page = doc.pages.add
    # Pretend payload — content doesn't matter, only that Filter=DCTDecode
    # gates the pass against re-encoding.
    raw = 'jpeg-like-blob' * 64
    img = add_image_xobject(doc, stream: raw, filter: :DCTDecode)
    attach_image_to_page(doc, page, img)
    original_stream = img.stream.to_s.dup

    new_exporter.send(:reflate_uncompressed_images, doc)

    assert_equal :DCTDecode, img[:Filter],
                 'DCT-encoded images must keep their original filter'
    assert_equal original_stream, img.stream.to_s,
                 'DCT-encoded streams must pass through byte-identical'
  end

  test 'reflate_uncompressed_images survives PDFArray indirect objects in the document' do
    # `doc.each` walks every indirect object — arrays included. The
    # image-detection helper must filter them out before any keyed
    # lookup, otherwise PDFArray#[] raises TypeError on Symbol keys
    # (real-world failure observed against a captured slide deck).
    doc = HexaPDF::Document.new
    page = doc.pages.add
    page[:MediaBox] = doc.add([0, 0, 612, 792])  # indirect PDFArray
    img = add_image_xobject(doc, stream: 'x' * 1024)
    attach_image_to_page(doc, page, img)

    assert_nothing_raised do
      new_exporter.send(:reflate_uncompressed_images, doc)
    end
    assert_equal :FlateDecode, img[:Filter]
  end

  test 'reflate_uncompressed_images leaves already-Flate images untouched' do
    doc = HexaPDF::Document.new
    page = doc.pages.add
    pre_deflated = Zlib::Deflate.deflate('payload' * 100, Zlib::DEFAULT_COMPRESSION)
    img = add_image_xobject(doc, stream: pre_deflated, filter: :FlateDecode)
    attach_image_to_page(doc, page, img)
    original_stream = img.stream.to_s.dup

    new_exporter.send(:reflate_uncompressed_images, doc)

    assert_equal original_stream, img.stream.to_s,
                 'already-Flate streams should not be re-encoded'
    assert_equal :FlateDecode, img[:Filter]
  end

  test 'merge of N captures with identical bodies produces a smaller PDF than the unoptimized sum' do
    # Sanity: with the post-process in place, exporting a 3-slide deck
    # whose captures are byte-identical (FakeEchoes ships the same PDF
    # bytes every time) ends up smaller than 3× one capture, because the
    # shared resources collapse under dedup / object-stream compression.
    presentation = make_deck(3)
    fake = FakeEchoes.new
    exporter = Przn::ScreenshotPdfExporter.new(presentation, base_dir: '.',
                                                theme: Przn::Theme.default, terminal: fake)

    one_capture_size = FakeEchoes::PDF_PAGE.bytesize
    Tempfile.create(['przn-shrink', '.pdf']) do |out|
      exporter.export(out.path)
      merged = File.size(out.path)
      # Lower bound check: HexaPDF's container overhead means the merged
      # file is never literally smaller than one of the inputs, but it
      # should be well under 3× the per-slide size — the optimization
      # has to pull its weight at minimum at the metadata layer.
      assert_operator merged, :<, 3 * one_capture_size,
                      "expected merged size #{merged} < 3 × #{one_capture_size}"
    end
  end

  test 'default quality (no --pdf-quality flag) maps to /ebook' do
    e = Przn::ScreenshotPdfExporter.new(make_deck(1), base_dir: '.',
                                         theme: Przn::Theme.default, terminal: FakeEchoes.new)
    assert_equal '/ebook', e.instance_variable_get(:@quality)
  end

  test '--pdf-quality preset names map to the correct gs settings' do
    {
      'low'    => '/screen',
      'medium' => '/ebook',
      'high'   => '/printer',
      'max'    => '/prepress',
    }.each do |name, expected|
      e = Przn::ScreenshotPdfExporter.new(make_deck(1), base_dir: '.',
                                           theme: Przn::Theme.default,
                                           terminal: FakeEchoes.new, quality: name)
      assert_equal expected, e.instance_variable_get(:@quality),
                   "expected --pdf-quality #{name} to resolve to #{expected}"
    end
  end

  test '--pdf-quality lossless resolves to :lossless and skips shell-out' do
    e = Przn::ScreenshotPdfExporter.new(make_deck(1), base_dir: '.',
                                         theme: Przn::Theme.default,
                                         terminal: FakeEchoes.new, quality: 'lossless')
    assert_equal :lossless, e.instance_variable_get(:@quality)

    # Force gs to look present so the only reason shrink_with_ghostscript
    # could no-op is the :lossless gate. Set PRZN_GS to /bin/true which
    # ALWAYS exits 0 — if @quality didn't short-circuit, the system call
    # would run and create the tmp file.
    ENV['PRZN_GS'] = '/bin/true'
    Tempfile.create(['gs-lossless', '.pdf']) do |f|
      f.write('%PDF-1.4 fake'); f.flush
      e.send(:shrink_with_ghostscript, f.path)
      refute File.exist?("#{f.path}.gs.tmp"), 'lossless quality must not invoke gs'
    end
  end

  test '--pdf-quality with an unknown value raises ArgumentError at construction' do
    assert_raise(ArgumentError) do
      Przn::ScreenshotPdfExporter.new(make_deck(1), base_dir: '.',
                                       theme: Przn::Theme.default,
                                       terminal: FakeEchoes.new, quality: 'extreme')
    end
  end

  test 'gs_path returns :disabled when PRZN_GS is set to an empty string' do
    ENV['PRZN_GS'] = ''
    assert_equal :disabled, new_exporter.send(:gs_path)
  end

  test 'gs_path returns :missing when PRZN_GS points at a binary that is not on PATH' do
    ENV['PRZN_GS'] = '/definitely/not/a/real/binary/gs-fake'
    assert_equal :missing, new_exporter.send(:gs_path)
  end

  test 'shrink_with_ghostscript silently no-ops when PRZN_GS is disabled' do
    ENV['PRZN_GS'] = ''
    Tempfile.create(['gs-noop', '.pdf']) do |f|
      f.write('%PDF-1.4 fake'); f.flush
      original_size = File.size(f.path)
      original_stderr = $stderr
      sink = StringIO.new
      $stderr = sink
      begin
        new_exporter.send(:shrink_with_ghostscript, f.path)
      ensure
        $stderr = original_stderr
      end
      assert_equal '', sink.string, 'disabled gs path should not print install hint'
      assert_equal original_size, File.size(f.path), 'file must be untouched when disabled'
    end
  end

  test 'raises when the terminal never produces the requested PDF (capture not implemented)' do
    silent = Object.new
    %i[clear hide_cursor show_cursor enter_alt_screen leave_alt_screen flush].each { |m| silent.define_singleton_method(m) {} }
    silent.define_singleton_method(:write) { |_| }
    silent.define_singleton_method(:move_to) { |_r, _c| }
    silent.define_singleton_method(:width)  { 120 }
    silent.define_singleton_method(:height) { 30 }
    silent.define_singleton_method(:cell_pixel_size) { [10, 20] }

    presentation = make_deck(1)
    exporter = Przn::ScreenshotPdfExporter.new(presentation, base_dir: '.', theme: Przn::Theme.default, terminal: silent)

    # Shrink the timeout so the test doesn't hang for 10s.
    Przn::ScreenshotPdfExporter.send(:remove_const, :CAPTURE_TIMEOUT)
    Przn::ScreenshotPdfExporter.const_set(:CAPTURE_TIMEOUT, 0.2)
    begin
      Tempfile.create(['przn-screenshot', '.pdf']) do |out|
        assert_raise(RuntimeError) { exporter.export(out.path) }
      end
    ensure
      Przn::ScreenshotPdfExporter.send(:remove_const, :CAPTURE_TIMEOUT)
      Przn::ScreenshotPdfExporter.const_set(:CAPTURE_TIMEOUT, 10)
    end
  end
end
