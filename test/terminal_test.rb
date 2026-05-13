# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class TerminalTest < Test::Unit::TestCase
  def setup
    @out = StringIO.new
    @terminal = Przn::Terminal.new(input: StringIO.new, output: @out)
  end

  sub_test_case 'enter_alt_screen' do
    test 'switches to the alt buffer and disables every mouse-tracking mode' do
      @terminal.enter_alt_screen
      assert_equal "\e[?1049h\e[?1006l\e[?1003l\e[?1002l\e[?1000l", @out.string
    end
  end

  sub_test_case 'leave_alt_screen' do
    test "disables mouse tracking before switching back, so leaked state never lands on the user's shell" do
      @terminal.leave_alt_screen
      mouse_off_at = @out.string.index("\e[?1006l")
      alt_off_at   = @out.string.index("\e[?1049l")
      assert_not_nil mouse_off_at, 'mouse-off sequence missing'
      assert_not_nil alt_off_at,   'alt-screen-off sequence missing'
      assert_operator mouse_off_at, :<, alt_off_at
    end
  end
end
