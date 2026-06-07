# frozen_string_literal: true

require 'test_helper'

class ParserTest < Test::Unit::TestCase
  # ============================================================
  # Rabbit Markdown compatible features
  # https://rabbit-shocker.org/ja/sample/markdown/rabbit.html
  # ============================================================

  sub_test_case 'Rabbit: slide splitting' do
    test 'splits on h1 headings' do
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

    test 'does not split on h2 or deeper' do
      md = <<~MD
        # Title

        ## Sub-heading

        ### Sub-sub
      MD
      slides = Przn::Parser.split_slides(md)
      assert_equal 1, slides.size
    end

    test 'does not split on # inside fenced code blocks' do
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

    test 'handles content before first h1' do
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

  sub_test_case 'Rabbit: headings' do
    test 'parses h1 as slide title' do
      slide = Przn::Parser.parse_slide("# Title\n")
      heading = slide.blocks.find { |b| b[:type] == :heading }
      assert_equal 1, heading[:level]
      assert_equal 'Title', heading[:content]
    end

    test 'parses h2-h6 within a slide' do
      slide = Przn::Parser.parse_slide("## Sub\n### Deep\n")
      headings = slide.blocks.select { |b| b[:type] == :heading }
      assert_equal 2, headings[0][:level]
      assert_equal 'Sub', headings[0][:content]
      assert_equal 3, headings[1][:level]
      assert_equal 'Deep', headings[1][:content]
    end
  end

  sub_test_case 'Rabbit: unordered lists (*)' do
    test 'parses * items' do
      slide = Przn::Parser.parse_slide("* foo\n* bar\n* baz\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_not_nil list
      assert_equal 3, list[:items].size
      assert_equal 'foo', list[:items][0][:text]
      assert_equal 'bar', list[:items][1][:text]
      assert_equal 'baz', list[:items][2][:text]
    end

    test 'parses nested lists with indentation' do
      slide = Przn::Parser.parse_slide("* top\n  * nested\n    * deep\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_equal 3, list[:items].size
      assert_equal 0, list[:items][0][:depth]
      assert_equal 1, list[:items][1][:depth]
      assert_equal 2, list[:items][2][:depth]
    end

    test 'handles continuation lines' do
      slide = Przn::Parser.parse_slide("* first line\n  continuation\n* second\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_equal 2, list[:items].size
      assert_match(/first line.*continuation/, list[:items][0][:text])
    end
  end

  sub_test_case 'Rabbit: ordered lists' do
    test 'parses numbered items' do
      slide = Przn::Parser.parse_slide("1. one\n2. two\n3. three\n")
      list = slide.blocks.find { |b| b[:type] == :ordered_list }
      assert_not_nil list
      assert_equal 3, list[:items].size
      assert_equal 'one', list[:items][0][:text]
    end

    test 'parses nested ordered lists' do
      slide = Przn::Parser.parse_slide("1. top\n   1. nested\n")
      list = slide.blocks.find { |b| b[:type] == :ordered_list }
      assert_equal 2, list[:items].size
      assert_equal 0, list[:items][0][:depth]
      assert_equal 1, list[:items][1][:depth]
    end
  end

  sub_test_case 'Rabbit: definition lists' do
    test 'parses term and definition' do
      slide = Przn::Parser.parse_slide("Rabbit\n:   a presentation tool\n")
      dl = slide.blocks.find { |b| b[:type] == :definition_list }
      assert_not_nil dl
      assert_equal 'Rabbit', dl[:term]
      assert_equal 'a presentation tool', dl[:definition]
    end

    test 'parses multi-line definition with continuation' do
      md = "term\n:   line 1\n    line 2\n"
      slide = Przn::Parser.parse_slide(md)
      dl = slide.blocks.find { |b| b[:type] == :definition_list }
      assert_equal 'term', dl[:term]
      assert_equal "line 1\nline 2", dl[:definition]
    end

    test 'non-definition text becomes paragraph' do
      slide = Przn::Parser.parse_slide("just a line\n")
      para = slide.blocks.find { |b| b[:type] == :paragraph }
      assert_not_nil para
      assert_equal 'just a line', para[:content]
    end
  end

  sub_test_case 'Rabbit: code blocks' do
    test 'parses fenced code block with language' do
      md = "```ruby\nputs 'hi'\n```\n"
      slide = Przn::Parser.parse_slide(md)
      code = slide.blocks.find { |b| b[:type] == :code_block }
      assert_not_nil code
      assert_equal "puts 'hi'\n", code[:content]
      assert_equal 'ruby', code[:language]
    end

    test 'parses fenced code block without language' do
      md = "```\nsome code\n```\n"
      slide = Przn::Parser.parse_slide(md)
      code = slide.blocks.find { |b| b[:type] == :code_block }
      assert_nil code[:language]
    end

    test 'parses indented code block (4 spaces)' do
      md = "    # comment\n    def foo\n      bar\n    end\n"
      slide = Przn::Parser.parse_slide(md)
      code = slide.blocks.find { |b| b[:type] == :code_block }
      assert_not_nil code
      assert_match(/# comment/, code[:content])
      assert_match(/def foo/, code[:content])
    end

    test 'parses kramdown IAL {: lang=} on indented code block' do
      md = "    def foo\n      bar\n    end\n{: lang=\"ruby\"}\n"
      slide = Przn::Parser.parse_slide(md)
      code = slide.blocks.find { |b| b[:type] == :code_block }
      assert_equal 'ruby', code[:language]
    end
  end

  sub_test_case 'Rabbit: block quotes' do
    test 'parses single-line blockquote' do
      slide = Przn::Parser.parse_slide("> hello\n")
      bq = slide.blocks.find { |b| b[:type] == :blockquote }
      assert_equal 'hello', bq[:content]
    end

    test 'parses multi-line blockquote' do
      slide = Przn::Parser.parse_slide("> line 1\n> line 2\n")
      bq = slide.blocks.find { |b| b[:type] == :blockquote }
      assert_equal "line 1\nline 2", bq[:content]
    end
  end

  sub_test_case 'Rabbit: tables' do
    test 'parses table with header and rows' do
      md = "| H1 | H2 |\n|---|---|\n| a | b |\n| c | d |\n"
      slide = Przn::Parser.parse_slide(md)
      table = slide.blocks.find { |b| b[:type] == :table }
      assert_not_nil table
      assert_equal ['H1', 'H2'], table[:header]
      assert_equal 2, table[:rows].size
      assert_equal ['a', 'b'], table[:rows][0]
      assert_equal ['c', 'd'], table[:rows][1]
    end
  end

  sub_test_case 'Comments' do
    test 'XML form: <!-- ... --> single-line is skipped' do
      md = "before\n<!-- hidden -->\nafter\n"
      slide = Przn::Parser.parse_slide(md)
      texts = slide.blocks.select { |b| b[:type] == :paragraph }.map { |b| b[:content] }
      assert_include texts, 'before'
      assert_include texts, 'after'
      assert_not_include texts, 'hidden'
    end

    test 'XML form: <!-- ... --> multi-line is skipped' do
      md = "before\n<!--\nhidden line 1\nhidden line 2\n-->\nafter\n"
      slide = Przn::Parser.parse_slide(md)
      texts = slide.blocks.select { |b| b[:type] == :paragraph }.map { |b| b[:content] }
      assert_include texts, 'before'
      assert_include texts, 'after'
      assert_not_include texts, 'hidden line 1'
      assert_not_include texts, 'hidden line 2'
    end

    test 'kramdown form: {::comment} block is skipped' do
      md = "before\n{::comment}\nhidden\n{:/comment}\nafter\n"
      slide = Przn::Parser.parse_slide(md)
      texts = slide.blocks.select { |b| b[:type] == :paragraph }.map { |b| b[:content] }
      assert_include texts, 'before'
      assert_include texts, 'after'
      assert_not_include texts, 'hidden'
    end
  end

  sub_test_case 'Rabbit: alignment ({:.center}, {:.right})' do
    test 'parses {:.center}' do
      md = "{:.center}\ncentered text\n"
      slide = Przn::Parser.parse_slide(md)
      align = slide.blocks.find { |b| b[:type] == :align }
      assert_equal :center, align[:align]
    end

    test 'parses {:.right}' do
      md = "{:.right}\nright text\n"
      slide = Przn::Parser.parse_slide(md)
      align = slide.blocks.find { |b| b[:type] == :align }
      assert_equal :right, align[:align]
    end
  end

  sub_test_case 'Rabbit: inline - *emphasis*' do
    test 'parses *emphasis* as italic' do
      assert_equal [[:italic, 'word']], Przn::Parser.parse_inline('*word*')
    end
  end

  sub_test_case 'Rabbit: inline - ~~strikethrough~~' do
    test 'parses ~~strikethrough~~' do
      assert_equal [[:strikethrough, 'word']], Przn::Parser.parse_inline('~~word~~')
    end
  end

  sub_test_case 'Rabbit: inline - {::tag}' do
    test 'parses {::tag name="x-large"}text{:/tag}' do
      result = Przn::Parser.parse_inline('{::tag name="x-large"}big{:/tag}')
      assert_equal [[:tag, 'big', 'x-large']], result
    end
  end

  sub_test_case 'Rabbit: inline - {::note}' do
    test 'parses {::note}text{:/note}' do
      result = Przn::Parser.parse_inline('{::note}note text{:/note}')
      assert_equal [[:note, 'note text']], result
    end
  end

  sub_test_case 'Rabbit: inline - {::wait/}' do
    test 'skips {::wait/}' do
      result = Przn::Parser.parse_inline('{::wait/}text')
      assert_equal [[:text, 'text']], result
    end
  end

  sub_test_case 'XML-style inline' do
    test 'parses <size=NAME>...</size>' do
      assert_equal [[:tag, 'big', 'x-large']], Przn::Parser.parse_inline('<size=x-large>big</size>')
      assert_equal [[:tag, 'max', '7']],       Przn::Parser.parse_inline('<size=7>max</size>')
    end

    test 'parses <color=NAME>...</color>' do
      assert_equal [[:tag, 'warn', 'red']],    Przn::Parser.parse_inline('<color=red>warn</color>')
      assert_equal [[:tag, 'hex', 'ff5555']],  Przn::Parser.parse_inline('<color=ff5555>hex</color>')
    end

    test '<color> accepts quoted values (HTML / kramdown parity with <font color>)' do
      assert_equal [[:tag, 'warn', 'red']],
                   Przn::Parser.parse_inline('<color="red">warn</color>')
      assert_equal [[:tag, 'warn', 'red']],
                   Przn::Parser.parse_inline("<color='red'>warn</color>")
      assert_equal [[:tag, 'hex', 'ff5555']],
                   Przn::Parser.parse_inline('<color="ff5555">hex</color>')
    end

    test '<color> accepts leading # on hex codes' do
      assert_equal [[:tag, 'hex', '#ff5555']],
                   Przn::Parser.parse_inline('<color=#ff5555>hex</color>')
      assert_equal [[:tag, 'hex', '#ff5555']],
                   Przn::Parser.parse_inline('<color="#ff5555">hex</color>')
    end

    test '<size> accepts quoted values too' do
      assert_equal [[:tag, 'big', '5']], Przn::Parser.parse_inline('<size="5">big</size>')
      assert_equal [[:tag, 'big', 'x-large']],
                   Przn::Parser.parse_inline("<size='x-large'>big</size>")
    end

    test '<font color="..."> remains supported (HTML4 form)' do
      assert_equal [[:font, 'warn', {color: 'red'}]],
                   Przn::Parser.parse_inline('<font color="red">warn</font>')
    end

    test 'parses <note>...</note>' do
      assert_equal [[:note, 'side']], Przn::Parser.parse_inline('<note>side</note>')
    end

    test 'skips <wait/>' do
      assert_equal [[:text, 'text']], Przn::Parser.parse_inline('<wait/>text')
    end

    test 'parses <br>, <br/>, <br /> into a :break segment (force line break)' do
      assert_equal [[:text, 'a'], [:break], [:text, 'b']],
                   Przn::Parser.parse_inline('a<br>b')
      assert_equal [[:text, 'a'], [:break], [:text, 'b']],
                   Przn::Parser.parse_inline('a<br/>b')
      assert_equal [[:text, 'a'], [:break], [:text, 'b']],
                   Przn::Parser.parse_inline('a<br />b')
      # Case-insensitive too.
      assert_equal [[:text, 'a'], [:break], [:text, 'b']],
                   Przn::Parser.parse_inline('a<BR>b')
    end

    test 'consecutive <br><br> yield two :break segments (one blank line between)' do
      assert_equal [[:text, 'a'], [:break], [:break], [:text, 'b']],
                   Przn::Parser.parse_inline('a<br><br>b')
    end

    test '<br> inside <size> splits into two :tag segments + :break' do
      assert_equal [[:tag, 'si', '2'], [:break], [:tag, 'ze', '2']],
                   Przn::Parser.parse_inline('<size=2>si<br>ze</size>')
    end

    test '<br> inside <color> splits into two :tag segments + :break' do
      assert_equal [[:tag, 'a', 'red'], [:break], [:tag, 'b', 'red']],
                   Przn::Parser.parse_inline('<color=red>a<br>b</color>')
    end

    test '<br> inside <font> splits, carrying the same attrs across' do
      result = Przn::Parser.parse_inline('<font face="Menlo">a<br>b</font>')
      assert_equal [[:font, 'a', {face: 'Menlo'}], [:break], [:font, 'b', {face: 'Menlo'}]],
                   result
    end

    test '<br> inside <note> splits the note across lines' do
      assert_equal [[:note, 'a'], [:break], [:note, 'b']],
                   Przn::Parser.parse_inline('<note>a<br>b</note>')
    end

    test '<br> inside kramdown {::tag} splits too' do
      assert_equal [[:tag, 'a', 'red'], [:break], [:tag, 'b', 'red']],
                   Przn::Parser.parse_inline('{::tag name="red"}a<br>b{:/tag}')
    end

    test 'interleaves XML tags with surrounding text' do
      result = Przn::Parser.parse_inline('hi <size=3>X</size> there')
      assert_equal [[:text, 'hi '], [:tag, 'X', '3'], [:text, ' there']], result
    end

    test '&lt; / &gt; / &amp; decode to literal characters' do
      assert_equal [[:text, '<']], Przn::Parser.parse_inline('&lt;')
      assert_equal [[:text, '>']], Przn::Parser.parse_inline('&gt;')
      assert_equal [[:text, '&']], Przn::Parser.parse_inline('&amp;')
    end

    test '&lt;note&gt; renders as literal text, not the note tag' do
      result = Przn::Parser.parse_inline('&lt;note&gt;')
      # No :note segment — and the three decoded text pieces coalesce
      # back into a single text segment.
      assert_equal [[:text, '<note>']], result
    end

    test 'bare & does not fragment the surrounding text into multiple segments' do
      # h1 like `# A & Bのあとに日本語のテキスト` must stay as one :text run
      # so the title becomes one OSC 66 multicell sequence — otherwise a
      # proportional title font (with h=2) gets visible padding gaps
      # around the `&`.
      assert_equal [[:text, 'A & Bのあとに日本語のテキスト']],
                   Przn::Parser.parse_inline('A & Bのあとに日本語のテキスト')
    end

    test 'rejects mismatched closing tag (left as plain text)' do
      result = Przn::Parser.parse_inline('<size=3>X</color>')
      assert_equal :text, result[0][0]
    end

    test 'parses <font face="...">...</font> with spaces in family' do
      assert_equal [[:font, 'Title', {face: 'Helvetica Neue'}]],
                   Przn::Parser.parse_inline('<font face="Helvetica Neue">Title</font>')
    end

    test 'parses {::font name="..."}...{:/font} (folds name= into :face)' do
      assert_equal [[:font, 'Title', {face: 'Helvetica Neue'}]],
                   Przn::Parser.parse_inline('{::font name="Helvetica Neue"}Title{:/font}')
    end

    test 'font tag mixes with surrounding plain text' do
      result = Przn::Parser.parse_inline('hi <font face="Menlo">code</font> there')
      assert_equal [[:text, 'hi '], [:font, 'code', {face: 'Menlo'}], [:text, ' there']], result
    end

    test 'parses <font face="..." size="..." color="..."> with all three attrs' do
      result = Przn::Parser.parse_inline('<font face="Menlo" size="3" color="red">code</font>')
      assert_equal [[:font, 'code', {face: 'Menlo', size: '3', color: 'red'}]], result
    end

    test 'parses <font> with unquoted attribute values' do
      result = Przn::Parser.parse_inline('<font face=Helvetica color=red>hi</font>')
      assert_equal [[:font, 'hi', {face: 'Helvetica', color: 'red'}]], result
    end

    test "<font> attribute order doesn't matter" do
      result = Przn::Parser.parse_inline('<font size="3" face="Menlo">x</font>')
      assert_equal [[:font, 'x', {face: 'Menlo', size: '3'}]], result
    end
  end

  sub_test_case 'XML-style block alignment' do
    test '<center>...</center> emits :align then :paragraph' do
      slide = Przn::Parser.parse("# t\n\n<center><size=3>Hello</size></center>\n").slides[0]
      align = slide.blocks.find { |b| b[:type] == :align }
      para  = slide.blocks.find { |b| b[:type] == :paragraph }
      assert_equal :center, align[:align]
      assert_equal '<size=3>Hello</size>', para[:content]
    end

    test '<right>...</right> emits :align :right then :paragraph' do
      slide = Przn::Parser.parse("# t\n\n<right>X</right>\n").slides[0]
      align = slide.blocks.find { |b| b[:type] == :align }
      para  = slide.blocks.find { |b| b[:type] == :paragraph }
      assert_equal :right, align[:align]
      assert_equal 'X', para[:content]
    end
  end

  sub_test_case 'Step boundary: <wait/> as a block' do
    def content_types(slide)
      slide.blocks.map { |b| b[:type] }.reject { |t| t == :blank }
    end

    test 'a `<wait/>` on its own line is captured as a `:wait` block' do
      slide = Przn::Parser.parse("# t\n\nFirst.\n\n<wait/>\n\nSecond.\n").slides[0]
      assert_equal [:heading, :paragraph, :wait, :paragraph], content_types(slide)
    end

    test 'self-closing `<wait />` and paired `<wait></wait>` are also block-level' do
      ['<wait/>', '<wait />', '<wait></wait>'].each do |form|
        slide = Przn::Parser.parse("# t\n\nA.\n\n#{form}\n\nB.\n").slides[0]
        assert_equal [:heading, :paragraph, :wait, :paragraph], content_types(slide),
                     "expected `#{form}` to parse as a :wait block"
      end
    end

    test 'kramdown `{::wait/}` on its own line is also block-level' do
      slide = Przn::Parser.parse("# t\n\nA.\n\n{::wait/}\n\nB.\n").slides[0]
      assert_equal [:heading, :paragraph, :wait, :paragraph], content_types(slide)
    end

    test 'inline `<wait/>` inside prose still drops silently (back-compat)' do
      # The README's "Wait marker" slide describes the marker mid-paragraph;
      # it must continue to be inline-eaten with no `:wait` block emitted.
      slide = Przn::Parser.parse(
        "# t\n\nThe <wait/> marker is reserved for future use.\n"
      ).slides[0]
      refute(slide.blocks.any? { |b| b[:type] == :wait },
             "inline <wait/> must not produce a block-level :wait")
    end
  end

  sub_test_case 'Action: <action target= .../>' do
    test '<action target="..." x="..." y="..."/> is captured as an :action block' do
      slide = Przn::Parser.parse(%(# t\n\n<action target="box" x="50%" y="80%"/>\n)).slides[0]
      action = slide.blocks.find { |b| b[:type] == :action }
      assert_not_nil action
      assert_equal 'box', action[:attrs][:target]
      assert_equal '50%', action[:attrs][:x]
      assert_equal '80%', action[:attrs][:y]
    end

    test 'an <action> without a target attr is silently dropped' do
      slide = Przn::Parser.parse(%(# t\n\n<action x="10c"/>\n)).slides[0]
      refute(slide.blocks.any? { |b| b[:type] == :action },
             'an <action> with no target= must not produce a block')
    end

    test 'arbitrary overrides ride through (z=, opacity=, width=, etc.)' do
      slide = Przn::Parser.parse(
        %(# t\n\n<action target="box" x="10c" y="5c" z="-1" opacity="0.5"/>\n)
      ).slides[0]
      action = slide.blocks.find { |b| b[:type] == :action }
      assert_equal '-1',  action[:attrs][:z]
      assert_equal '0.5', action[:attrs][:opacity]
    end

    test 'duration="500ms" lands as block[:duration_ms] == 500.0' do
      slide = Przn::Parser.parse(
        %(# t\n\n<action target="box" x="50" duration="500ms"/>\n)
      ).slides[0]
      action = slide.blocks.find { |b| b[:type] == :action }
      assert_equal 500.0, action[:duration_ms]
    end

    test 'duration="0.5s" → 500.0 ms' do
      slide = Przn::Parser.parse(
        %(# t\n\n<action target="box" x="50" duration="0.5s"/>\n)
      ).slides[0]
      assert_equal 500.0, slide.blocks.find { |b| b[:type] == :action }[:duration_ms]
    end

    test 'unit-less duration="500" defaults to milliseconds' do
      slide = Przn::Parser.parse(
        %(# t\n\n<action target="box" x="50" duration="500"/>\n)
      ).slides[0]
      assert_equal 500.0, slide.blocks.find { |b| b[:type] == :action }[:duration_ms]
    end

    test 'unparseable duration is silently dropped (no duration_ms key)' do
      slide = Przn::Parser.parse(
        %(# t\n\n<action target="box" x="50" duration="garbage"/>\n)
      ).slides[0]
      action = slide.blocks.find { |b| b[:type] == :action }
      assert_not_nil action, 'the action itself should still be captured'
      refute action.key?(:duration_ms), 'garbage duration must not produce a duration_ms key'
    end
  end

  sub_test_case 'Cross-slide reference: <ref id= .../>' do
    test '<ref id="x"/> is captured as a :ref block carrying the foreign id' do
      slide = Przn::Parser.parse(%(# t\n\n<ref id="quote"/>\n)).slides[0]
      ref = slide.blocks.find { |b| b[:type] == :ref }
      assert_not_nil ref, 'a <ref id=…/> should produce a :ref block'
      assert_equal 'quote', ref[:attrs][:id]
    end

    test '<ref> with extra attrs (override surface) keeps them on the block' do
      slide = Przn::Parser.parse(%(# t\n\n<ref id="quote" x="20%" y="80%"/>\n)).slides[0]
      ref = slide.blocks.find { |b| b[:type] == :ref }
      assert_equal 'quote', ref[:attrs][:id]
      assert_equal '20%',   ref[:attrs][:x]
      assert_equal '80%',   ref[:attrs][:y]
    end

    test '<ref> without an id= is silently dropped (matches <action> w/o target=)' do
      slide = Przn::Parser.parse(%(# t\n\n<ref x="10c"/>\n)).slides[0]
      assert(slide.blocks.none? { |b| b[:type] == :ref },
             'a <ref> with no id= must not produce a block')
    end
  end

  sub_test_case 'Composite container: <group id= ...> ... </group>' do
    test '<group id="x"> ... </group> parses into a :group block with children' do
      md = "# t\n\n<group id=\"box\">\n## Inner\n\n<rect x=\"5\" y=\"5\" width=\"3\" height=\"3\" fill=\"red\"/>\n</group>\n"
      slide = Przn::Parser.parse(md).slides[0]
      g = slide.blocks.find { |b| b[:type] == :group }
      assert_not_nil g
      assert_equal 'box', g[:attrs][:id]
      kinds = g[:children].map { |c| c[:type] }
      assert_includes kinds, :heading
      assert_includes kinds, :shape
    end

    test '<group> without an id= is silently dropped (matches <ref> w/o id=)' do
      md = "# t\n\n<group>\nContent\n</group>\n"
      slide = Przn::Parser.parse(md).slides[0]
      assert(slide.blocks.none? { |b| b[:type] == :group },
             'a <group> without id= must not produce a block')
    end

    test 'nested <group> works (inner group becomes a child of the outer)' do
      md = "# t\n\n<group id=\"outer\">\nOuter text\n<group id=\"inner\">\nInner text\n</group>\nMore outer\n</group>\n"
      slide = Przn::Parser.parse(md).slides[0]
      outer = slide.blocks.find { |b| b[:type] == :group && b[:attrs][:id] == 'outer' }
      assert_not_nil outer, 'outer group should be at slide top level'
      inner = outer[:children].find { |c| c[:type] == :group && c[:attrs][:id] == 'inner' }
      assert_not_nil inner, 'inner group should be a child of the outer group'
    end

    test 'missing </group> close tag is silently dropped — no crash, no partial block' do
      md = "# t\n\n<group id=\"never-closed\">\nContent\n\nMore content\n"
      slide = nil
      assert_nothing_raised { slide = Przn::Parser.parse(md).slides[0] }
      assert(slide.blocks.none? { |b| b[:type] == :group },
             'an unclosed <group> must not produce a block (partial bundle would silently mislead)')
    end
  end

  sub_test_case 'Slide background: <bg .../>' do
    test 'self-closing block with from/to/angle is captured as :bg' do
      slide = Przn::Parser.parse(%(# t\n\n<bg from="#1a1a2e" to="#16213e" angle="90"/>\n)).slides[0]
      bg = slide.blocks.find { |b| b[:type] == :bg }
      assert_not_nil bg
      assert_equal '#1a1a2e', bg[:attrs][:from]
      assert_equal '#16213e', bg[:attrs][:to]
      assert_equal '90',      bg[:attrs][:angle]
    end

    test 'self-closing block with single color is also captured as :bg' do
      slide = Przn::Parser.parse(%(# t\n\n<bg color="#1a1a2e"/>\n)).slides[0]
      bg = slide.blocks.find { |b| b[:type] == :bg }
      assert_not_nil bg
      assert_equal '#1a1a2e', bg[:attrs][:color]
    end

    test "attribute order doesn't matter" do
      slide = Przn::Parser.parse(%(# t\n\n<bg angle="45" to="#fff" from="#000"/>\n)).slides[0]
      bg = slide.blocks.find { |b| b[:type] == :bg }
      assert_equal '#000', bg[:attrs][:from]
      assert_equal '#fff', bg[:attrs][:to]
      assert_equal '45',   bg[:attrs][:angle]
    end

    test 'extra attributes (e.g. type=) pass through' do
      slide = Przn::Parser.parse(%(# t\n\n<bg from="#000" to="#fff" type="linear"/>\n)).slides[0]
      bg = slide.blocks.find { |b| b[:type] == :bg }
      assert_equal 'linear', bg[:attrs][:type]
    end

    test 'unquoted attribute values are accepted (HTML5-ish)' do
      slide = Przn::Parser.parse(%(# t\n\n<bg from=#1a1a2e to=#16213e angle=90 />\n)).slides[0]
      bg = slide.blocks.find { |b| b[:type] == :bg }
      assert_equal '#1a1a2e', bg[:attrs][:from]
      assert_equal '#16213e', bg[:attrs][:to]
      assert_equal '90',      bg[:attrs][:angle]
    end

    test 'single-quoted attribute values are accepted' do
      slide = Przn::Parser.parse(%(# t\n\n<bg color='#1a1a2e'/>\n)).slides[0]
      bg = slide.blocks.find { |b| b[:type] == :bg }
      assert_equal '#1a1a2e', bg[:attrs][:color]
    end

    test 'quoted and unquoted attributes can be mixed on the same tag' do
      slide = Przn::Parser.parse(%(# t\n\n<bg from=#000 to='#fff' angle="45"/>\n)).slides[0]
      bg = slide.blocks.find { |b| b[:type] == :bg }
      assert_equal '#000', bg[:attrs][:from]
      assert_equal '#fff', bg[:attrs][:to]
      assert_equal '45',   bg[:attrs][:angle]
    end
  end

  sub_test_case 'Image: <img src=".../>' do
    test 'self-closing XML form desugars to the same :image block as ![](path)' do
      slide = Przn::Parser.parse(%(# t\n\n<img src="doge.png"/>\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_not_nil img
      assert_equal 'doge.png', img[:path]
      assert_equal '',         img[:alt]
      assert_nil               img[:title]
      assert_equal({},         img[:attrs])
    end

    test 'alt / title attributes are lifted off :attrs onto the block' do
      slide = Przn::Parser.parse(%(# t\n\n<img src="doge.png" alt="a doge" title="hover"/>\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal 'a doge', img[:alt]
      assert_equal 'hover',  img[:title]
      assert_equal({},       img[:attrs])
    end

    test 'remaining attributes pass through with string keys (matching ![]{:...} parse)' do
      slide = Przn::Parser.parse(%(# t\n\n<img src="doge.png" relative_height="70"/>\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal '70', img[:attrs]['relative_height']
    end

    test 'missing src is ignored (no :image block emitted)' do
      slide = Przn::Parser.parse(%(# t\n\n<img alt="oops"/>\n)).slides[0]
      assert_nil slide.blocks.find { |b| b[:type] == :image }
    end

    test 'height="N%" / width="N%" are aliases for relative_height / relative_width' do
      slide = Przn::Parser.parse(%(# t\n\n<img src="doge.png" height="40%" width="60%"/>\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal '40', img[:attrs]['relative_height']
      assert_equal '60', img[:attrs]['relative_width']
      assert_nil img[:attrs]['height']
      assert_nil img[:attrs]['width']
    end

    test 'explicit relative_height wins over the height="N%" alias' do
      slide = Przn::Parser.parse(%(# t\n\n<img src="doge.png" height="40%" relative_height="70"/>\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal '70', img[:attrs]['relative_height']
    end

    test 'height without a % suffix passes through (no alias rewrite)' do
      slide = Przn::Parser.parse(%(# t\n\n<img src="doge.png" height="40"/>\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal '40', img[:attrs]['height']
      assert_nil img[:attrs]['relative_height']
    end

    test 'markdown form: height="N%" alias works in {:...} IAL too' do
      slide = Przn::Parser.parse(%(# t\n\n![](pic.png){:height="40%" width="60%"}\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal '40', img[:attrs]['relative_height']
      assert_equal '60', img[:attrs]['relative_width']
    end

    test 'unquoted attribute values work on <img> too' do
      slide = Przn::Parser.parse(%(# t\n\n<img src=doge.png height=70% />\n)).slides[0]
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal 'doge.png', img[:path]
      assert_equal '70', img[:attrs]['relative_height']
    end
  end

  sub_test_case 'Shapes: <rect>, <circle>, <ellipse>, <line>, <polyline>, <polygon>' do
    test '<rect> parses to {type: :shape, kind: :rect, attrs: {...}}' do
      slide = Przn::Parser.parse(
        %(# t\n\n<rect x="10" y="5" width="20" height="6" fill="tomato"/>\n)
      ).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_not_nil block
      assert_equal :rect, block[:kind]
      assert_equal '10', block[:attrs]['x']
      assert_equal '5',  block[:attrs]['y']
      assert_equal '20', block[:attrs]['width']
      assert_equal '6',  block[:attrs]['height']
      assert_equal 'tomato', block[:attrs]['fill']
    end

    test '<circle> kind and attrs' do
      slide = Przn::Parser.parse(%(# t\n\n<circle cx="50%" cy="50%" r="5" fill="cyan"/>\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :circle, block[:kind]
      assert_equal '50%', block[:attrs]['cx']
      assert_equal '50%', block[:attrs]['cy']
      assert_equal '5',   block[:attrs]['r']
    end

    test '<ellipse> kind and attrs' do
      slide = Przn::Parser.parse(%(# t\n\n<ellipse cx="50" cy="15" rx="20" ry="6"/>\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :ellipse, block[:kind]
      assert_equal '20', block[:attrs]['rx']
      assert_equal '6',  block[:attrs]['ry']
    end

    test '<line> kind and endpoint attrs' do
      slide = Przn::Parser.parse(
        %(# t\n\n<line x1="10" y1="5" x2="70" y2="5" stroke="white" stroke-width="0.3"/>\n)
      ).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :line, block[:kind]
      assert_equal '10', block[:attrs]['x1']
      assert_equal '70', block[:attrs]['x2']
      assert_equal 'white', block[:attrs]['stroke']
      assert_equal '0.3',   block[:attrs]['stroke-width']
    end

    test '<polyline> captures points unchanged' do
      slide = Przn::Parser.parse(
        %(# t\n\n<polyline points="10,5 30,15 50,5 70,15" stroke="lime"/>\n)
      ).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :polyline, block[:kind]
      assert_equal '10,5 30,15 50,5 70,15', block[:attrs]['points']
    end

    test '<polygon> captures points unchanged' do
      slide = Przn::Parser.parse(
        %(# t\n\n<polygon points="50,2 60,15 40,15" fill="gold"/>\n)
      ).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :polygon, block[:kind]
      assert_equal '50,2 60,15 40,15', block[:attrs]['points']
    end

    test '<path> captures the d attribute' do
      slide = Przn::Parser.parse(%(# t\n\n<path d="M 10 5 L 70 5 Z" stroke="red"/>\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :path, block[:kind]
      assert_equal 'M 10 5 L 70 5 Z', block[:attrs]['d']
      assert_equal 'red', block[:attrs]['stroke']
    end

    test '<arrow> kind and endpoint attrs' do
      slide = Przn::Parser.parse(
        %(# t\n\n<arrow x1="10" y1="15" x2="70" y2="15" stroke="red" stroke-width="0.5"/>\n)
      ).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :arrow, block[:kind]
      assert_equal '10', block[:attrs]['x1']
      assert_equal '70', block[:attrs]['x2']
      assert_equal 'red', block[:attrs]['stroke']
    end

    test 'unquoted attribute values work on shape tags too' do
      slide = Przn::Parser.parse(%(# t\n\n<circle cx=40 cy=10 r=4 fill=cyan />\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :circle, block[:kind]
      assert_equal '40', block[:attrs]['cx']
      assert_equal 'cyan', block[:attrs]['fill']
    end

    test 'parameter-less shape tag still emits a block (renderer skips if geometry incomplete)' do
      slide = Przn::Parser.parse(%(# t\n\n<rect/>\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :shape }
      assert_equal :rect, block[:kind]
      assert_equal({}, block[:attrs])
    end
  end

  sub_test_case 'Absolute-position text: <at x y>...</at>' do
    test 'XML form parses x/y and content' do
      slide = Przn::Parser.parse(%(# t\n\n<at x="10" y="5">hello</at>\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :at }
      assert_not_nil block
      assert_equal '10',    block[:attrs][:x]
      assert_equal '5',     block[:attrs][:y]
      assert_equal 'hello', block[:content]
    end

    test 'kramdown form parses x/y and content' do
      slide = Przn::Parser.parse(%(# t\n\n{::at x="10" y="5"}hello{:/at}\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :at }
      assert_not_nil block
      assert_equal '10',    block[:attrs][:x]
      assert_equal '5',     block[:attrs][:y]
      assert_equal 'hello', block[:content]
    end

    test 'inner markup is preserved verbatim in content (renderer parses it inline)' do
      slide = Przn::Parser.parse(%(# t\n\n<at x="10" y="5"><size=3>BIG</size></at>\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :at }
      assert_equal '<size=3>BIG</size>', block[:content]
    end

    test 'unquoted attribute values work on <at> too' do
      slide = Przn::Parser.parse(%(# t\n\n<at x=10 y=50%>hi</at>\n)).slides[0]
      block = slide.blocks.find { |b| b[:type] == :at }
      assert_equal '10',  block[:attrs][:x]
      assert_equal '50%', block[:attrs][:y]
      assert_equal 'hi',  block[:content]
    end
  end

  sub_test_case 'Slide layouts: h1 IAL + <slot/>' do
    test 'h1 IAL {layout=name} sets slide.layout and strips the IAL from the title' do
      slide = Przn::Parser.parse(%(# Title {layout=two-column}\n\nbody\n)).slides[0]
      assert_equal 'two-column', slide.layout
      h1 = slide.blocks.find { |b| b[:type] == :heading && b[:level] == 1 }
      assert_equal 'Title', h1[:content]
    end

    test 'kramdown form {:layout=name} is equivalent' do
      slide = Przn::Parser.parse(%(# Title {:layout=two-column}\n)).slides[0]
      assert_equal 'two-column', slide.layout
      assert_equal 'Title', slide.blocks.find { |b| b[:type] == :heading }[:content]
    end

    test 'YAML-flow form {layout: name} is equivalent' do
      slide = Przn::Parser.parse(%(# Title {layout: two-column}\n)).slides[0]
      assert_equal 'two-column', slide.layout
      assert_equal 'Title', slide.blocks.find { |b| b[:type] == :heading }[:content]
    end

    test 'unrelated trailing {curlies} are left in the heading content as-is' do
      slide = Przn::Parser.parse(%(# What about {curlies}?\n)).slides[0]
      assert_nil slide.layout
      assert_equal 'What about {curlies}?', slide.blocks.find { |b| b[:type] == :heading }[:content]
    end

    test 'extra IAL keys ride on slide.attrs (forward-compat for future per-slide metadata)' do
      slide = Przn::Parser.parse(%(# Title {layout=two-column align=center}\n)).slides[0]
      assert_equal 'two-column', slide.layout
      assert_equal({align: 'center'}, slide.attrs)
    end

    test 'h1 without IAL leaves slide.layout nil' do
      slide = Przn::Parser.parse(%(# Title\n\nbody\n)).slides[0]
      assert_nil slide.layout
    end

    test '<slot/> parses to a :slot block with no name' do
      slide = Przn::Parser.parse(%(# t {layout=two-column}\n\nleft\n\n<slot/>\n\nright\n)).slides[0]
      slot = slide.blocks.find { |b| b[:type] == :slot }
      assert_not_nil slot
      assert_nil slot[:name]
    end

    test '<slot name="right"/> parses to a :slot block carrying the name' do
      slide = Przn::Parser.parse(%(# t {layout=two-column}\n\n<slot name="right"/>\n\nright\n)).slides[0]
      slot = slide.blocks.find { |b| b[:type] == :slot }
      assert_equal 'right', slot[:name]
    end
  end

  sub_test_case 'Rabbit: inline - mixed' do
    test 'parses mixed inline formatting' do
      result = Przn::Parser.parse_inline('hello *world* and **bold**')
      assert_equal :text, result[0][0]
      assert_equal 'hello ', result[0][1]
      assert_equal :italic, result[1][0]
      assert_equal 'world', result[1][1]
      assert_equal :text, result[2][0]
      assert_equal :bold, result[3][0]
      assert_equal 'bold', result[3][1]
    end
  end

  sub_test_case 'Rabbit: title slide with definition list metadata' do
    test 'parses title slide metadata' do
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
      assert_equal 'subtitle', dls[0][:term]
      assert_equal 'My Subtitle', dls[0][:definition]
      assert_equal 'author', dls[1][:term]
      assert_equal 'Author Name', dls[1][:definition]
    end
  end

  sub_test_case 'Rabbit: full presentation' do
    test 'parses multi-slide presentation' do
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
      assert_equal 'Title', pres.slides[0].blocks.find { |b| b[:type] == :heading }[:content]
      assert_equal 'Content', pres.slides[1].blocks.find { |b| b[:type] == :heading }[:content]
      assert_equal 'End', pres.slides[2].blocks.find { |b| b[:type] == :heading }[:content]
    end
  end

  # ============================================================
  # przn extensions (beyond Rabbit Markdown)
  # ============================================================

  sub_test_case 'przn extension: - as unordered list bullet' do
    test 'parses - items' do
      slide = Przn::Parser.parse_slide("- foo\n- bar\n- baz\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_not_nil list
      assert_equal 3, list[:items].size
      assert_equal 'foo', list[:items][0][:text]
      assert_equal 'bar', list[:items][1][:text]
      assert_equal 'baz', list[:items][2][:text]
    end

    test 'parses nested - lists' do
      slide = Przn::Parser.parse_slide("- top\n  - nested\n    - deep\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_equal 3, list[:items].size
      assert_equal 0, list[:items][0][:depth]
      assert_equal 1, list[:items][1][:depth]
      assert_equal 2, list[:items][2][:depth]
    end

    test 'can mix * and - in the same list' do
      slide = Przn::Parser.parse_slide("* first\n- second\n* third\n")
      list = slide.blocks.find { |b| b[:type] == :unordered_list }
      assert_equal 3, list[:items].size
    end
  end

  sub_test_case 'przn extension: {::tag} with numeric size (1-7)' do
    test 'parses numeric size tag' do
      result = Przn::Parser.parse_inline('{::tag name="7"}max{:/tag}')
      assert_equal [[:tag, 'max', '7']], result
    end

    test 'SIZE_SCALES maps all 7 levels' do
      (1..7).each do |n|
        assert_equal n, Przn::Parser::SIZE_SCALES[n.to_s]
      end
    end
  end

  sub_test_case 'przn extension: **bold** inline' do
    test 'parses **bold**' do
      assert_equal [[:bold, 'word']], Przn::Parser.parse_inline('**word**')
    end
  end

  sub_test_case 'przn extension: `code` inline' do
    test 'parses `code`' do
      assert_equal [[:code, 'foo']], Przn::Parser.parse_inline('`foo`')
    end
  end

  sub_test_case 'przn extension: images' do
    test 'parses ![alt](path)' do
      slide = Przn::Parser.parse_slide("![doge](doge.png)\n")
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_not_nil img
      assert_equal 'doge.png', img[:path]
      assert_equal 'doge', img[:alt]
    end

    test 'parses ![](path "title")' do
      slide = Przn::Parser.parse_slide('![](pic.jpg "My Title")' + "\n")
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal 'pic.jpg', img[:path]
      assert_equal 'My Title', img[:title]
    end

    test 'parses image with kramdown attributes' do
      slide = Przn::Parser.parse_slide("![](pic.png){:relative_height='80'}\n")
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal 'pic.png', img[:path]
      assert_equal '80', img[:attrs]['relative_height']
    end

    test 'parses image with multi-line attributes' do
      md = "![](pic.png){:relative_height='80'\n                relative_width='50'}\n"
      slide = Przn::Parser.parse_slide(md)
      img = slide.blocks.find { |b| b[:type] == :image }
      assert_equal 'pic.png', img[:path]
      assert_equal '80', img[:attrs]['relative_height']
      assert_equal '50', img[:attrs]['relative_width']
    end
  end
end
