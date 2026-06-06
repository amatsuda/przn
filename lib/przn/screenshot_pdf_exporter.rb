# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'digest'
require 'zlib'

module Przn
  # Default PDF export: drives the live renderer, asks the terminal to save
  # each rendered slide as a one-page vector PDF via OSC 7772 `capture`,
  # then concatenates the per-slide PDFs into a single multi-page PDF.
  # Requires Echoes (or any terminal that implements the same capture
  # command); use `export_pdf_prawn` instead for environments where that's
  # not possible (CI, headless).
  def self.export_pdf(file, output, theme: nil, quality: nil)
    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    base_dir = File.dirname(File.expand_path(file))
    ScreenshotPdfExporter.new(presentation, base_dir: base_dir, theme: theme, quality: quality).export(output)
    puts "Generated: #{output}"
  end

  # Renders each slide live to the user's terminal, asks the terminal to save
  # the current pane as a vector PDF via Echoes' OSC 7772 `capture` command,
  # then concatenates the per-slide PDFs into a single multi-page PDF.
  #
  # Trade-off vs the Prawn-based PdfExporter:
  #   - Pixel-perfect match with what's on screen (gradients, fonts, OSC 66
  #     sized text, bullet glyphs, the lot) — but vector, so the result is
  #     small, sharp at any zoom, and text stays selectable.
  #   - Requires running inside a terminal that implements OSC 7772 capture
  #     to a `.pdf` path (i.e. Echoes). Won't work in CI or any terminal that
  #     doesn't honor the command.
  #
  # Echoes-side wire format (independent of przn):
  #   ESC ] 7772 ; capture ; <absolute_path> BEL
  #   On receipt, Echoes saves the current pane to the path. The file
  #   extension picks the format — `.pdf` produces a single-page vector PDF
  #   by replaying the same drawing pipeline into a CGPDFContext instead of
  #   the screen's NSGraphicsContext.
  class ScreenshotPdfExporter
    OSC = "\e]7772".freeze
    BEL = "\a".freeze

    POLL_INTERVAL = 0.05  # seconds between file-existence checks
    CAPTURE_TIMEOUT = 10  # seconds per slide before giving up

    # Maps the user-facing `--pdf-quality` flag onto Ghostscript's
    # `-dPDFSETTINGS` preset names. `:lossless` skips the gs pass
    # entirely (lossless HexaPDF layers only — useful when image
    # fidelity matters more than file size). `nil` means "use the
    # default", which is `:medium`.
    QUALITY_PRESETS = {
      'lossless' => :lossless,
      'low'      => '/screen',
      'medium'   => '/ebook',
      'high'     => '/printer',
      'max'      => '/prepress',
    }.freeze
    DEFAULT_QUALITY = 'medium'

    def initialize(presentation, base_dir: '.', theme: nil, terminal: nil, quality: nil)
      @presentation = presentation
      @base_dir = base_dir
      @theme = theme || Theme.default
      @terminal = terminal || Terminal.new
      @renderer = Renderer.new(@terminal, base_dir: base_dir, theme: theme, export_mode: true, presentation: presentation)
      @quality = resolve_quality(quality)
    end

    def export(output_path)
      require 'hexapdf'

      Dir.mktmpdir('przn-capture') do |dir|
        pdf_paths = capture_all_slides(dir)
        merge_pdfs(pdf_paths, output_path)
      end
    end

    private

    def capture_all_slides(dir)
      paths = []
      @terminal.enter_alt_screen
      @terminal.hide_cursor
      @presentation.slides.each_with_index do |slide, i|
        pdf_path = File.join(dir, format('slide-%04d.pdf', i))
        @renderer.render(slide, current: i, total: @presentation.total)
        request_capture(pdf_path)
        wait_for_capture(pdf_path)
        paths << pdf_path
      end
      paths
    ensure
      @terminal.write "#{OSC};bg-clear#{BEL}"
      @terminal.write ImageUtil.kitty_clear_all if ImageUtil.kitty_terminal?
      @terminal.show_cursor
      @terminal.leave_alt_screen
      @terminal.flush
    end

    def request_capture(path)
      @terminal.write "#{OSC};capture;#{path}#{BEL}"
      @terminal.flush
    end

    def wait_for_capture(path)
      deadline = Time.now + CAPTURE_TIMEOUT
      until File.exist?(path) && File.size?(path).to_i.positive?
        if Time.now > deadline
          raise "Capture timed out for #{path}. " \
                'Is Echoes running and recent enough to honor OSC 7772 `capture` to a .pdf path?'
        end
        sleep POLL_INTERVAL
      end
      # Small grace period to ensure the PDF write is fully flushed.
      sleep POLL_INTERVAL
    end

    def merge_pdfs(pdf_paths, output_path)
      raise 'No slides captured' if pdf_paths.empty?

      output = HexaPDF::Document.new
      pdf_paths.each do |path|
        src = HexaPDF::Document.open(path)
        src.pages.each do |page|
          output.pages << output.import(page)
        end
      end

      # Three lossless passes before write. Page surfaces stay
      # byte-identical; only the encoding of the underlying objects
      # shrinks.
      #   1. Dedup image XObjects — repeated logos / shared backgrounds
      #      become a single shared object.
      #   2. Re-Flate uncompressed image streams.
      #   3. HexaPDF's task(:optimize) collapses metadata into object
      #      streams and rewrites xref as binary streams.
      dedup_image_xobjects(output)
      reflate_uncompressed_images(output)
      output.task(:optimize,
                  compact: true,
                  object_streams: :generate,
                  xref_streams: :generate)

      output.write(output_path)

      # Optional lossy post-process. Echoes' OSC 7772 capture embeds
      # `<img>` and shape rasters at their NATIVE source resolution
      # (a 24-megapixel phone photo embedded as a slide thumbnail
      # stays at 24MP in the captured PDF). Re-Flating that pixel
      # data, as the three lossless passes above do, doesn't help —
      # photographic content compresses 10-50× better as JPEG.
      #
      # Ghostscript's `-dPDFSETTINGS=/ebook` downsamples raster
      # images to 150 DPI and re-encodes them as JPEG. We shell out
      # if `gs` is on PATH; if not, the file is left as-is with a
      # friendly hint on stderr. Lossy in the strict sense, but the
      # `/ebook` preset is widely considered visually indistinguishable
      # at presentation viewing distances.
      shrink_with_ghostscript(output_path)
    end

    # Resolve the Ghostscript binary path the recompression pass will
    # use. Three layers, in order:
    #   1. `PRZN_GS=` (explicitly empty) — opt out, no warning. Used
    #      by tests and by anyone who wants the lossless-only pipeline.
    #   2. `PRZN_GS=<path>` — explicit override (custom build, brew
    #      keg-only path, etc).
    #   3. Default: probe PATH for `gs`. Missing binary → returns
    #      :missing so the caller can print the install hint once.
    def gs_path
      env = ENV['PRZN_GS']
      return :disabled if env == ''
      bin = env && !env.empty? ? env : 'gs'
      found = `which #{bin} 2>/dev/null`.chomp
      found.empty? ? :missing : found
    end

    def shrink_with_ghostscript(path)
      return if @quality == :lossless
      gs = gs_path
      case gs
      when :disabled then return
      when :missing
        warn 'Hint: install Ghostscript (`brew install ghostscript`) for a 5-20× ' \
             'size reduction on image-heavy decks. Skipping recompression. ' \
             'Pass --pdf-quality lossless to silence this hint.'
        return
      end

      tmp = "#{path}.gs.tmp"
      ok = system(gs,
                  '-q',
                  '-dQUIET', '-dNOPAUSE', '-dBATCH', '-dSAFER',
                  '-sDEVICE=pdfwrite',
                  "-dPDFSETTINGS=#{@quality}",
                  '-dCompatibilityLevel=1.5',
                  "-sOutputFile=#{tmp}",
                  path,
                  out: File::NULL, err: File::NULL)
      if ok && File.exist?(tmp) && File.size(tmp).positive? && File.size(tmp) < File.size(path)
        FileUtils.mv(tmp, path)
      else
        FileUtils.rm_f(tmp)
      end
    end

    def resolve_quality(raw)
      key = (raw || DEFAULT_QUALITY).to_s.downcase
      preset = QUALITY_PRESETS[key]
      unless preset
        raise ArgumentError,
              "unknown --pdf-quality #{raw.inspect}; expected one of " \
              "#{QUALITY_PRESETS.keys.join(', ')}"
      end
      preset
    end

    # Find image XObjects whose stream bytes are byte-for-byte identical
    # and collapse them into a single shared object — the case being:
    # a slide background or repeated logo gets captured into N
    # per-slide PDFs independently, then HexaPDF imports each one as
    # its own object. Hashing the stream bytes is enough to recognise
    # them; the later pages' XObject resource entries are pointed at
    # the first occurrence's indirect reference and the duplicate
    # objects are swept by the subsequent compact-optimize pass.
    def dedup_image_xobjects(doc)
      by_hash = {}
      doc.pages.each do |page|
        resources = page[:Resources]
        next unless resources && resources[:XObject]
        xobjects = resources[:XObject]
        xobjects.each do |name, xobj|
          next unless image_xobject?(xobj)
          h = Digest::SHA256.hexdigest(xobj.stream.to_s)
          if (canonical = by_hash[h])
            xobjects[name] = canonical unless canonical.equal?(xobj)
          else
            by_hash[h] = xobj
          end
        end
      end
      # Sweep the now-orphaned duplicates.
      doc.task(:optimize, compact: true)
    end

    # Apply best-strength Flate to image streams that arrived
    # uncompressed (or compressed by a filter Flate can outperform).
    # JPEG (`DCTDecode`) and JPEG-2000 (`JPXDecode`) streams are
    # already entropy-coded — re-encoding them losslessly cannot
    # help and lossy re-encoding would need an external image
    # library. Streams that grow under Flate (rare; happens when
    # the input is already near maximum entropy) are left alone.
    def reflate_uncompressed_images(doc)
      doc.each do |obj|
        next unless image_xobject?(obj)
        filter = Array(obj[:Filter])
        next if filter.include?(:FlateDecode) ||
                filter.include?(:DCTDecode) ||
                filter.include?(:JPXDecode)
        raw = obj.stream.to_s
        next if raw.empty?
        deflated = Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)
        next if deflated.bytesize >= raw.bytesize
        obj.stream = deflated
        obj[:Filter] = :FlateDecode
      end
    end

    def image_xobject?(obj)
      # `doc.each` walks every indirect object, including HexaPDF::PDFArray
      # whose `[]` raises on a Symbol key. Gate on the underlying value
      # being a dict (Hash) before any keyed lookup so arrays and plain
      # scalars are silently skipped.
      return false unless obj.respond_to?(:value) && obj.value.is_a?(Hash)
      obj[:Type] == :XObject && obj[:Subtype] == :Image
    end
  end
end
