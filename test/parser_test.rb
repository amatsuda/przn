# frozen_string_literal: true

require "test_helper"

class ParserTest < Test::Unit::TestCase
  # ============================================================
  # Rabbit Markdown compatible features
  # https://rabbit-shocker.org/ja/sample/markdown/rabbit.html
  # ============================================================

  sub_test_case "Rabbit: slide splitting" do
    test "splits on h1 headings" do
      md = <<~MD
        # Slide 1

        content 1

        # Slide 2

        content 2

        # Slide 3

        content 3
      MD
      slides = Przn::Parser.split_slides(md)
      assert_equal 3, slides.size
      assert_match(/# Slide 1/, slides[0])
      assert_match(/# Slide 2/, slides[1])
      assert_match(/# Slide 3/, slides[2])
    end

    test "does not split on h2 or deeper" do
      md = <<~MD
        # Title

        ## Sub-heading

        ### Sub-sub
      MD
      slides = Przn::Parser.split_slides(md)
      assert_equal 1, slides.size
    end

    test "does not split on # inside fenced code blocks" do
      md = <<~MD
        # Slide 1

        ```ruby
        # this is a comment
        ```

        # Slide 2
      MD
      slides = Przn::Parser.split_slides(md)
      assert_equal 2, slides.size
      assert_match(/# this is a comment/, slides[0])
    end

    test "handles content before first h1" do
      md = <<~MD
        preamble text

        # First Slide
      MD
      slides = Przn::Parser.split_slides(md)
      assert_equal 2, slides.size
      assert_match(/preamble/, slides[0])
      assert_match(/# First Slide/, slides[1])
    end
  end

  sub_test_case "Rabbit: headings" do
    test "parses h1 as slide title" do
      slide = Przn::Parser.parse_slide("# Title\n")
      heading = slide.blocks.find { |b| b[:type] == :heading }
      assert_equal 1, heading[:level]
      assert_equal "Title", heading[:content]
    end

    test "parses h2-h6 within a slide" do
      slide = Przn::Parser.parse_slide("## Sub\n### Deep\n")
      headings = slide.blocks.select { |b| b[:type] == :heading }
      assert_equal 2, headings[0][:level]
      assert_equal "Sub", headings[0][:content]
      assert_equal 3, headings[1][:level]
      assert_equal "Deep", headings[1][:content]
    end
  end

  sub_test_case "Rabbit: unordered lists (*)" do
    test "parses * items" do
      slide = Przn::Parser.parse_slide("* foo\n* bar\n* baz\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_not_nil list
      assert_equal 3, list[:items].size
      assert_equal "foo", list[:items][0][:text]
      assert_equal "bar", list[:items][1][:text]
      assert_equal "baz", list[:items][2][:text]
    end

    test "parses nested lists with indentation" do
      slide = Przn::Parser.parse_slide("* top\n  * nested\n    * deep\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_equal 3, list[:items].size
      assert_equal 0, list[:items][0][:depth]
      assert_equal 1, list[:items][1][:depth]
      assert_equal 2, list[:items][2][:depth]
    end

    test "handles continuation lines" do
      slide = Przn::Parser.parse_slide("* first line\n  continuation\n* second\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_equal 2, list[:items].size
      assert_match(/first line.*continuation/, list[:items][0][:text])
    end
  end

  sub_test_case "Rabbit: ordered lists" do
    test "parses numbered items" do
      slide = Przn::Parser.parse_slide("1. one\n2. two\n3. three\n")
      list = slide.blocks.find { |b| b[:type] == :ordered_list }
      assert_not_nil list
      assert_equal 3, list[:items].size
      assert_equal "one", list[:items][0][:text]
    end

    test "parses nested ordered lists" do
      slide = Przn::Parser.parse_slide("1. top\n   1. nested\n")
      list = slide.blocks.find { |b| b[:type] == :ordered_list }
      assert_equal 2, list[:items].size
      assert_equal 0, list[:items][0][:depth]
      assert_equal 1, list[:items][1][:depth]
    end
  end

  sub_test_case "Rabbit: definition lists" do
    test "parses term and definition" do
      slide = Przn::Parser.parse_slide("Rabbit\n:   a presentation tool\n")
      dl = slide.blocks.find { |b| b[:type] == :definition_list }
      assert_not_nil dl
      assert_equal "Rabbit", dl[:term]
      assert_equal "a presentation tool", dl[:definition]
    end

    test "parses multi-line definition with continuation" do
      md = "term\n:   line 1\n    line 2\n"
      slide = Przn::Parser.parse_slide(md)
      dl = slide.blocks.find { |b| b[:type] == :definition_list }
      assert_equal "term", dl[:term]
      assert_equal "line 1\nline 2", dl[:definition]
    end

    test "non-definition text becomes paragraph" do
      slide = Przn::Parser.parse_slide("just a line\n")
      para = slide.blocks.find { |b| b[:type] == :paragraph }
      assert_not_nil para
      assert_equal "just a line", para[:content]
    end
  end

  sub_test_case "Rabbit: code blocks" do
    test "parses fenced code block with language" do
      md = "```ruby\nputs 'hi'\n```\n"
      slide = Przn::Parser.parse_slide(md)
      code = slide.blocks.find { |b| b[:type] == :code_block }
      assert_not_nil code
      assert_equal "puts 'hi'\n", code[:content]
      assert_equal "ruby", code[:language]
    end

    test "parses fenced code block without language" do
      md = "```\nsome code\n```\n"
      slide = Przn::Parser.parse_slide(md)
      code = slide.blocks.find { |b| b[:type] == :code_block }
      assert_nil code[:language]
    end

    test "parses indented code block (4 spaces)" do
      md = "    # comment\n    def foo\n      bar\n    end\n"
      slide = Przn::Parser.parse_slide(md)
      code = slide.blocks.find { |b| b[:type] == :code_block }
      assert_not_nil code
      assert_match(/# comment/, code[:content])
      assert_match(/def foo/, code[:content])
    end

    test "parses kramdown IAL {: lang=} on indented code block" do
      md = "    def foo\n      bar\n    end\n{: lang=\"ruby\"}\n"
      slide = Przn::Parser.parse_slide(md)
      code = slide.blocks.find { |b| b[:type] == :code_block }
      assert_equal "ruby", code[:language]
    end
  end

  sub_test_case "Rabbit: block quotes" do
    test "parses single-line blockquote" do
      slide = Przn::Parser.parse_slide("> hello\n")
      bq = slide.blocks.find { |b| b[:type] == :blockquote }
      assert_equal "hello", bq[:content]
    end

    test "parses multi-line blockquote" do
      slide = Przn::Parser.parse_slide("> line 1\n> line 2\n")
      bq = slide.blocks.find { |b| b[:type] == :blockquote }
      assert_equal "line 1\nline 2", bq[:content]
    end
  end

  sub_test_case "Rabbit: tables" do
    test "parses table with header and rows" do
      md = "| H1 | H2 |\n|---|---|\n| a | b |\n| c | d |\n"
      slide = Przn::Parser.parse_slide(md)
      table = slide.blocks.find { |b| b[:type] == :table }
      assert_not_nil table
      assert_equal ["H1", "H2"], table[:header]
      assert_equal 2, table[:rows].size
      assert_equal ["a", "b"], table[:rows][0]
      assert_equal ["c", "d"], table[:rows][1]
    end
  end

  sub_test_case "Rabbit: {::comment}" do
    test "skips {::comment} blocks entirely" do
      md = "before\n{::comment}\nhidden\n{:/comment}\nafter\n"
      slide = Przn::Parser.parse_slide(md)
      texts = slide.blocks.select { |b| b[:type] == :paragraph }.map { |b| b[:content] }
      assert_include texts, "before"
      assert_include texts, "after"
      assert_not_include texts, "hidden"
    end
  end

  sub_test_case "Rabbit: alignment ({:.center}, {:.right})" do
    test "parses {:.center}" do
      md = "{:.center}\ncentered text\n"
      slide = Przn::Parser.parse_slide(md)
      align = slide.blocks.find { |b| b[:type] == :align }
      assert_equal :center, align[:align]
    end

    test "parses {:.right}" do
      md = "{:.right}\nright text\n"
      slide = Przn::Parser.parse_slide(md)
      align = slide.blocks.find { |b| b[:type] == :align }
      assert_equal :right, align[:align]
    end
  end

  sub_test_case "Rabbit: inline - *emphasis*" do
    test "parses *emphasis* as italic" do
      assert_equal [[:italic, "word"]], Przn::Parser.parse_inline("*word*")
    end
  end

  sub_test_case "Rabbit: inline - ~~strikethrough~~" do
    test "parses ~~strikethrough~~" do
      assert_equal [[:strikethrough, "word"]], Przn::Parser.parse_inline("~~word~~")
    end
  end

  sub_test_case "Rabbit: inline - {::tag}" do
    test "parses {::tag name=\"x-large\"}text{:/tag}" do
      result = Przn::Parser.parse_inline('{::tag name="x-large"}big{:/tag}')
      assert_equal [[:tag, "big", "x-large"]], result
    end
  end

  sub_test_case "Rabbit: inline - {::note}" do
    test "parses {::note}text{:/note}" do
      result = Przn::Parser.parse_inline("{::note}note text{:/note}")
      assert_equal [[:note, "note text"]], result
    end
  end

  sub_test_case "Rabbit: inline - {::wait/}" do
    test "skips {::wait/}" do
      result = Przn::Parser.parse_inline("{::wait/}text")
      assert_equal [[:text, "text"]], result
    end
  end

  sub_test_case "Rabbit: inline - mixed" do
    test "parses mixed inline formatting" do
      result = Przn::Parser.parse_inline("hello *world* and **bold**")
      assert_equal :text, result[0][0]
      assert_equal "hello ", result[0][1]
      assert_equal :italic, result[1][0]
      assert_equal "world", result[1][1]
      assert_equal :text, result[2][0]
      assert_equal :bold, result[3][0]
      assert_equal "bold", result[3][1]
    end
  end

  sub_test_case "Rabbit: title slide with definition list metadata" do
    test "parses title slide metadata" do
      md = <<~MD
        # Title

        subtitle
        :   My Subtitle

        author
        :   Author Name
      MD
      pres = Przn::Parser.parse(md)
      dls = pres.slides[0].blocks.select { |b| b[:type] == :definition_list }
      assert_equal 2, dls.size
      assert_equal "subtitle", dls[0][:term]
      assert_equal "My Subtitle", dls[0][:definition]
      assert_equal "author", dls[1][:term]
      assert_equal "Author Name", dls[1][:definition]
    end
  end

  sub_test_case "Rabbit: full presentation" do
    test "parses multi-slide presentation" do
      md = <<~MD
        # Title

        subtitle
        :   My Presentation

        author
        :   Me

        # Content

        * item 1
        * item 2

        # End

        Thank you
      MD
      pres = Przn::Parser.parse(md)
      assert_equal 3, pres.total
      assert_equal "Title", pres.slides[0].blocks.find { |b| b[:type] == :heading }[:content]
      assert_equal "Content", pres.slides[1].blocks.find { |b| b[:type] == :heading }[:content]
      assert_equal "End", pres.slides[2].blocks.find { |b| b[:type] == :heading }[:content]
    end
  end

  # ============================================================
  # przn extensions (beyond Rabbit Markdown)
  # ============================================================

  sub_test_case "przn extension: - as unordered list bullet" do
    test "parses - items" do
      slide = Przn::Parser.parse_slide("- foo\n- bar\n- baz\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_not_nil list
      assert_equal 3, list[:items].size
      assert_equal "foo", list[:items][0][:text]
      assert_equal "bar", list[:items][1][:text]
      assert_equal "baz", list[:items][2][:text]
    end

    test "parses nested - lists" do
      slide = Przn::Parser.parse_slide("- top\n  - nested\n    - deep\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_equal 3, list[:items].size
      assert_equal 0, list[:items][0][:depth]
      assert_equal 1, list[:items][1][:depth]
      assert_equal 2, list[:items][2][:depth]
    end

    test "can mix * and - in the same list" do
      slide = Przn::Parser.parse_slide("* first\n- second\n* third\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_equal 3, list[:items].size
    end
  end

  sub_test_case "przn extension: {::tag} with numeric size (1-7)" do
    test "parses numeric size tag" do
      result = Przn::Parser.parse_inline('{::tag name="7"}max{:/tag}')
      assert_equal [[:tag, "max", "7"]], result
    end

    test "SIZE_SCALES maps all 7 levels" do
      (1..7).each do |n|
        assert_equal n, Przn::Parser::SIZE_SCALES[n.to_s]
      end
    end
  end

  sub_test_case "przn extension: **bold** inline" do
    test "parses **bold**" do
      assert_equal [[:bold, "word"]], Przn::Parser.parse_inline("**word**")
    end
  end

  sub_test_case "przn extension: `code` inline" do
    test "parses `code`" do
      assert_equal [[:code, "foo"]], Przn::Parser.parse_inline("`foo`")
    end
  end
end
