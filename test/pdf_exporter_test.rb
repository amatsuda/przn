# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class PdfExporterTest < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry @tmpdir
  end

  def export(markdown, base_dir: '.', theme: nil)
    presentation = Przn::Parser.parse(markdown)
    output = File.join(@tmpdir, 'test.pdf')
    Przn::PdfExporter.new(presentation, base_dir: base_dir, theme: theme).export(output)
    output
  end

  def assert_pdf(path, page_count: nil)
    assert File.exist?(path), "PDF file should exist"
    assert File.size(path) > 0, "PDF file should not be empty"
    content = File.read(path, mode: 'rb')
    assert content.start_with?('%PDF'), "File should be a valid PDF"
    if page_count
      # Count page objects in PDF
      pages = content.scan(/\/Type\s*\/Page[^s]/).size
      assert_equal page_count, pages, "PDF should have #{page_count} pages"
    end
  end

  sub_test_case "basic export" do
    test "generates a valid PDF file" do
      path = export("# Hello\n\nWorld\n")
      assert_pdf path
    end

    test "generates one page per slide" do
      md = "# Slide 1\n\ncontent\n\n# Slide 2\n\ncontent\n\n# Slide 3\n\ncontent\n"
      path = export(md)
      assert_pdf path, page_count: 3
    end

    test "single slide produces one page" do
      path = export("# Only Slide\n\nHello\n")
      assert_pdf path, page_count: 1
    end
  end

  sub_test_case "block types" do
    test "exports headings" do
      path = export("# Title\n\n## Sub-heading\n")
      assert_pdf path
    end

    test "exports paragraphs" do
      path = export("# Slide\n\nA paragraph of text.\n")
      assert_pdf path
    end

    test "exports code blocks" do
      path = export("# Code\n\n```ruby\nputs 'hello'\n```\n")
      assert_pdf path
    end

    test "exports unordered lists" do
      path = export("# Lists\n\n- item 1\n- item 2\n- item 3\n")
      assert_pdf path
    end

    test "exports nested unordered lists" do
      path = export("# Lists\n\n- top\n  - nested\n    - deep\n")
      assert_pdf path
    end

    test "exports ordered lists" do
      path = export("# Lists\n\n1. one\n2. two\n3. three\n")
      assert_pdf path
    end

    test "exports definition lists" do
      path = export("# Defs\n\nterm\n:   definition\n")
      assert_pdf path
    end

    test "exports blockquotes" do
      path = export("# Quote\n\n> quoted text\n> more text\n")
      assert_pdf path
    end

    test "exports tables" do
      path = export("# Table\n\n| H1 | H2 |\n|---|---|\n| a | b |\n")
      assert_pdf path
    end

    test "exports blank lines" do
      path = export("# Slide\n\ntext\n\nmore text\n")
      assert_pdf path
    end
  end

  sub_test_case "inline formatting" do
    test "exports bold text" do
      path = export("# Slide\n\nThis is **bold** text.\n")
      assert_pdf path
    end

    test "exports italic text" do
      path = export("# Slide\n\nThis is *italic* text.\n")
      assert_pdf path
    end

    test "exports strikethrough text" do
      path = export("# Slide\n\nThis is ~~deleted~~ text.\n")
      assert_pdf path
    end

    test "exports inline code" do
      path = export("# Slide\n\nThis is `code` text.\n")
      assert_pdf path
    end

    test "exports notes" do
      path = export("# Slide\n\nVisible {::note}(note){:/note} text.\n")
      assert_pdf path
    end
  end

  sub_test_case "tags" do
    test "exports size tags" do
      path = export("# Slide\n\n{::tag name=\"x-large\"}Big{:/tag}\n")
      assert_pdf path
    end

    test "exports color tags" do
      path = export("# Slide\n\nnormal and {::tag name=\"red\"}red{:/tag} mixed\n")
      assert_pdf path
    end
  end

  sub_test_case "alignment" do
    test "exports centered text" do
      path = export("# Slide\n\n{:.center}\ncentered\n")
      assert_pdf path
    end

    test "exports right-aligned text" do
      path = export("# Slide\n\n{:.right}\nright\n")
      assert_pdf path
    end
  end

  sub_test_case "images" do
    test "skips missing images gracefully" do
      path = export("# Slide\n\n![](nonexistent.png)\n")
      assert_pdf path
    end

    test "embeds existing PNG image" do
      png_path = File.join(@tmpdir, 'test.png')
      create_minimal_png(png_path)
      path = export("# Slide\n\n![](test.png)\n", base_dir: @tmpdir)
      assert_pdf path
      assert File.size(path) > 500, "PDF with image should be larger"
    end
  end

  sub_test_case "build_formatted_text" do
    def build(text, pt = 18)
      presentation = Przn::Parser.parse("# dummy\n")
      exporter = Przn::PdfExporter.new(presentation)
      exporter.send(:build_formatted_text, text, pt)
    end

    def default_theme
      @default_theme ||= Przn::Theme.default
    end

    test "plain text" do
      result = build("hello")
      assert_equal [{text: "hello", size: 18, color: default_theme.colors[:foreground]}], result
    end

    test "bold" do
      result = build("**bold**")
      assert_equal [{text: "bold", size: 18, color: default_theme.colors[:foreground], styles: [:bold]}], result
    end

    test "italic" do
      result = build("*italic*")
      assert_equal [{text: "italic", size: 18, color: default_theme.colors[:foreground], styles: [:italic]}], result
    end

    test "color tag" do
      result = build('{::tag name="red"}text{:/tag}')
      assert_equal 1, result.size
      assert_equal 'FF5555', result[0][:color]
    end

    test "size tag" do
      result = build('{::tag name="x-large"}big{:/tag}')
      assert_equal 1, result.size
      assert_equal Przn::PdfExporter::SCALE_TO_PT[4], result[0][:size]
    end

    test "inline code" do
      result = build("`code`")
      assert_equal 1, result.size
      assert_equal " code ", result[0][:text]
      assert_equal default_theme.colors[:inline_code], result[0][:color]
    end

    test "note" do
      result = build("{::note}note{:/note}")
      assert_equal 1, result.size
      assert_equal default_theme.colors[:dim], result[0][:color]
      assert_operator result[0][:size], :<, 18
    end
  end

  sub_test_case "theme" do
    test "export with custom theme produces valid PDF" do
      theme = Przn::Theme.new(
        colors: {
          background: 'ff0000', foreground: '00ff00', heading: '0000ff',
          code_bg: '111111', dim: '222222', inline_code: '333333',
        },
        font: {family: nil},
      )
      path = export("# Hello\n\nWorld\n\n```ruby\nputs 1\n```\n", theme: theme)
      assert_pdf path
    end

    test "export with default theme still works" do
      path = export("# Hello\n\nWorld\n", theme: Przn::Theme.default)
      assert_pdf path
    end

    test "build_formatted_text uses theme colors" do
      theme = Przn::Theme.new(
        colors: {
          background: '000000', foreground: 'ffffff', heading: nil,
          code_bg: '111111', dim: '222222', inline_code: '333333',
        },
        font: {family: nil},
      )
      presentation = Przn::Parser.parse("# dummy\n")
      exporter = Przn::PdfExporter.new(presentation, theme: theme)

      result = exporter.send(:build_formatted_text, "hello", 18)
      assert_equal 'ffffff', result[0][:color]

      result = exporter.send(:build_formatted_text, "`code`", 18)
      assert_equal '333333', result[0][:color]

      result = exporter.send(:build_formatted_text, "{::note}note{:/note}", 18)
      assert_equal '222222', result[0][:color]
    end
  end

  sub_test_case "full sample files" do
    test "exports sample/sample.md" do
      sample = File.join(File.dirname(__dir__), 'sample', 'sample.md')
      return unless File.exist?(sample)

      md = File.read(sample)
      path = export(md, base_dir: File.join(File.dirname(__dir__), 'sample'))
      assert_pdf path
    end
  end

  private

  def create_minimal_png(path)
    require 'zlib'
    # Build a valid 1x1 white PNG from scratch
    signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack('C*')

    # IHDR: 1x1, 8-bit RGB
    ihdr_data = [1, 1, 8, 2, 0, 0, 0].pack('NNC5')
    ihdr = png_chunk('IHDR', ihdr_data)

    # IDAT: filter byte (0) + RGB white pixel (0xFF, 0xFF, 0xFF)
    raw = [0, 0xFF, 0xFF, 0xFF].pack('C*')
    idat = png_chunk('IDAT', Zlib::Deflate.deflate(raw))

    iend = png_chunk('IEND', '')

    File.binwrite(path, signature + ihdr + idat + iend)
  end

  def png_chunk(type, data)
    [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
  end
end
