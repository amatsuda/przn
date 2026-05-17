# frozen_string_literal: true

require 'test_helper'

class SlideTest < Test::Unit::TestCase
  sub_test_case '#notes' do
    test 'collects note contents from paragraphs' do
      slide = Przn::Parser.parse("# T\n\nHello {::note}a note{:/note} world\n").slides[0]
      assert_equal ['a note'], slide.notes
    end

    test 'collects notes from list items, headings, blockquotes' do
      md = <<~MD
        # T

        ## Sub {::note}heading note{:/note}

        - item {::note}list note{:/note}

        > quote <note>quote note</note>
      MD
      slide = Przn::Parser.parse(md).slides[0]
      assert_equal ['heading note', 'list note', 'quote note'], slide.notes
    end

    test 'returns [] when no notes' do
      slide = Przn::Parser.parse("# T\n\nplain text\n").slides[0]
      assert_equal [], slide.notes
    end
  end
end
