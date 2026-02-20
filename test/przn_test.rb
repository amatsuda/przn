# frozen_string_literal: true

require "test_helper"

class PrznTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Przn.const_defined?(:VERSION)
    end
  end
end
