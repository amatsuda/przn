# frozen_string_literal: true

require 'test_helper'

class PresentationTest < Test::Unit::TestCase
  Slide = Struct.new(:blocks)

  sub_test_case '#find_by_id' do
    test 'finds a block on the same slide by string-key id' do
      slides = [Slide.new([{type: :image, attrs: {'id' => 'logo', 'src' => 'a.png'}}])]
      pres = Przn::Presentation.new(slides)
      assert_equal slides[0].blocks[0], pres.find_by_id('logo')
    end

    test 'finds a block on a later slide by symbol-key id (parser quirk: :at keeps symbols)' do
      slides = [
        Slide.new([{type: :paragraph, content: 'cover'}]),
        Slide.new([{type: :at, attrs: {id: 'quote', x: 'center'}, content: 'Hi'}])
      ]
      pres = Przn::Presentation.new(slides)
      assert_equal slides[1].blocks[0], pres.find_by_id('quote')
    end

    test 'returns nil for an unknown id (no crash)' do
      pres = Przn::Presentation.new([Slide.new([{type: :paragraph, content: 'x'}])])
      assert_nil pres.find_by_id('not-there')
    end

    test 'first declaration wins on duplicate ids across slides' do
      slides = [
        Slide.new([{type: :at, attrs: {id: 'dup'}, content: 'first'}]),
        Slide.new([{type: :at, attrs: {id: 'dup'}, content: 'second'}])
      ]
      pres = Przn::Presentation.new(slides)
      assert_equal 'first', pres.find_by_id('dup')[:content],
                   'duplicate ids: first-by-slide-order wins (matches existing :action by_id behaviour)'
    end

    test 'skips :ref blocks when building the index (no transitive resolution in v1)' do
      # A :ref shouldn't be indexed under its own id even if it carried one —
      # otherwise <ref id="a"/> sitting on slide 1 would shadow a real source
      # on slide 2.
      slides = [
        Slide.new([{type: :ref, attrs: {id: 'q'}}]),
        Slide.new([{type: :at, attrs: {id: 'q'}, content: 'real source'}])
      ]
      pres = Przn::Presentation.new(slides)
      assert_equal 'real source', pres.find_by_id('q')[:content]
    end

    test 'lookup is idempotent (index memoised across calls)' do
      slides = [Slide.new([{type: :at, attrs: {id: 'q'}, content: 'once'}])]
      pres = Przn::Presentation.new(slides)
      assert_same pres.find_by_id('q'), pres.find_by_id('q')
    end

    test 'finds an id declared inside a group block (deck-wide recursion)' do
      inner = {type: :shape, kind: :rect, attrs: {'id' => 'inner-box', 'x' => '5'}}
      group = {type: :group, attrs: {id: 'outer'}, children: [inner]}
      pres = Przn::Presentation.new([Slide.new([group])])
      assert_equal group, pres.find_by_id('outer'), 'outer group itself is indexed'
      assert_equal inner, pres.find_by_id('inner-box'),
                   'an id declared inside a group must be reachable through find_by_id'
    end

    test 'recursion walks nested groups too' do
      inner = {type: :at, attrs: {id: 'deep'}, content: 'deep'}
      mid   = {type: :group, attrs: {id: 'mid'}, children: [inner]}
      outer = {type: :group, attrs: {id: 'outer'}, children: [mid]}
      pres = Przn::Presentation.new([Slide.new([outer])])
      assert_equal inner, pres.find_by_id('deep'), 'descend through nested groups'
    end
  end
end
