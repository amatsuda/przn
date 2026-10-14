# frozen_string_literal: true

require 'test_helper'

class PresenterRendererTest < Test::Unit::TestCase
  def preview_title(markdown, index: 1)
    presentation = Przn::Parser.parse(markdown)
    renderer = Przn::PresenterRenderer.new(nil, presentation: presentation)
    renderer.send(:preview_title, presentation.slides[index])
  end

  sub_test_case 'preview_title' do
    test 'returns the plain text of the next slide heading' do
      assert_equal 'Second', preview_title("# First\n\n# Second\n")
    end

    test 'strips inline markup from the heading' do
      md = "# First\n\n# **Bold** <size=large>big</size> <color=red>red</color> `code` &lt;tag&gt;\n"
      assert_equal 'Bold big red code <tag>', preview_title(md)
    end

    test 'drops inline notes and wait markers' do
      md = "# First\n\n# Title<note>speaker only</note><wait/>\n"
      assert_equal 'Title', preview_title(md)
    end

    test 'turns <br> into a space' do
      assert_equal 'one two', preview_title("# First\n\n# one<br>two\n")
    end
  end
end
