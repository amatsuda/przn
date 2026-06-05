# frozen_string_literal: true

require 'test_helper'

class CodeHighlighterTest < Test::Unit::TestCase
  sub_test_case 'highlight' do
    test 'returns nil when language is blank or nil' do
      assert_nil Przn::CodeHighlighter.highlight('foo', nil)
      assert_nil Przn::CodeHighlighter.highlight('foo', '')
    end

    test 'returns nil for unknown languages' do
      assert_nil Przn::CodeHighlighter.highlight('foo', 'klingon')
    end

    test 'tokenizes Ruby code into [color, value] pairs' do
      result = Przn::CodeHighlighter.highlight("def hello\n  42\nend\n", 'ruby')
      assert_kind_of Array, result
      # Token mix: 'def' (Keyword → cyan), 'hello' (Name.Function → green),
      # '42' (Literal.Number → magenta), 'end' (Keyword → cyan).
      colors = result.map(&:first).uniq.compact
      assert_includes colors, 'cyan'
      assert_includes colors, 'green'
      assert_includes colors, 'magenta'
    end

    test 'tokenizes Python code' do
      result = Przn::CodeHighlighter.highlight("def f(): return 42\n", 'python')
      assert_kind_of Array, result
      kw = result.find { |c, v| v == 'def' }
      assert_equal 'cyan', kw.first, "expected `def` to be a Keyword/cyan"
    end

    test 'comments map to bright_black' do
      result = Przn::CodeHighlighter.highlight("# hello\n42\n", 'ruby')
      comment_token = result.find { |_c, v| v.include?('#') }
      assert_equal 'bright_black', comment_token.first
    end

    test 'string literals map to green' do
      result = Przn::CodeHighlighter.highlight('"hello"', 'ruby')
      string_pieces = result.select { |c, _v| c == 'green' }
      refute_empty string_pieces, 'expected at least one green string-token piece'
    end

    test 'unknown token types fall back to nil (default fg)' do
      # Plain text the lexer marks as Text → nil.
      result = Przn::CodeHighlighter.highlight("plain words here\n", 'plaintext')
      assert(result.all? { |c, _v| c.nil? },
             "expected all colors nil for plaintext lexer: #{result.inspect}")
    end
  end

  sub_test_case 'caching' do
    test 'second call with the same code+language returns the cached array (identity-equal)' do
      # Same exact string → same cached tokens object.
      result1 = Przn::CodeHighlighter.highlight("def hi\n  1\nend\n", 'ruby')
      result2 = Przn::CodeHighlighter.highlight("def hi\n  1\nend\n", 'ruby')
      assert_same result1, result2,
                  'second highlight of the same (code, language) should return the cached object'
    end

    test 'different code re-tokenizes (different cache key)' do
      a = Przn::CodeHighlighter.highlight("def a; end\n", 'ruby')
      b = Przn::CodeHighlighter.highlight("def b; end\n", 'ruby')
      refute_same a, b, 'different code must produce a distinct cache entry'
    end

    test 'different language re-tokenizes (cache key includes language)' do
      code = "x = 1"
      a = Przn::CodeHighlighter.highlight(code, 'ruby')
      b = Przn::CodeHighlighter.highlight(code, 'python')
      refute_same a, b
    end
  end

  sub_test_case 'color_for' do
    test 'walks up the dotted token hierarchy' do
      # Literal.Number.Integer → falls back to Literal.Number → magenta.
      stub_token = Object.new
      def stub_token.qualname; 'Literal.Number.Integer'; end
      assert_equal 'magenta', Przn::CodeHighlighter.color_for(stub_token)
    end

    test 'returns nil when no ancestor matches' do
      stub_token = Object.new
      def stub_token.qualname; 'Generic.Output'; end
      assert_nil Przn::CodeHighlighter.color_for(stub_token)
    end
  end
end
