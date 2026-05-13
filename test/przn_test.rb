# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class PrznTest < Test::Unit::TestCase
  test 'VERSION' do
    assert do
      ::Przn.const_defined?(:VERSION)
    end
  end

  sub_test_case '.start' do
    def with_deck(content)
      f = Tempfile.new(['start_test', '.md'])
      f.write(content)
      f.flush
      yield f.path
    ensure
      f&.close!
    end

    test 'start_at: positions the presentation at the given 1-based slide' do
      deck = "# One\n\n# Two\n\n# Three\n\n# Four\n"
      with_deck(deck) do |path|
        controller = Przn.start(path, start_at: 3)
        presentation = controller.instance_variable_get(:@presentation)
        assert_equal 2, presentation.current  # 0-based, so slide 3 == index 2
      end
    end

    test 'start_at: clamps past the last slide' do
      deck = "# One\n\n# Two\n"
      with_deck(deck) do |path|
        controller = Przn.start(path, start_at: 99)
        presentation = controller.instance_variable_get(:@presentation)
        assert_equal 1, presentation.current  # clamped to last
      end
    end

    test 'without start_at the presentation begins at slide 1' do
      deck = "# One\n\n# Two\n"
      with_deck(deck) do |path|
        controller = Przn.start(path)
        presentation = controller.instance_variable_get(:@presentation)
        assert_equal 0, presentation.current
      end
    end
  end
end
