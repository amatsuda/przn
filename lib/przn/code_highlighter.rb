# frozen_string_literal: true

module Przn
  # Tokenizer wrapper around Rouge for fenced code blocks. Maps Rouge's
  # token tree to a small set of ANSI-name colors the renderer already
  # knows how to emit. Token types that don't match anything in the
  # table fall back to the default fg.
  #
  # Color scheme is hard-coded (no theme.yml hook yet) — tuned for the
  # dark-gray code-block background the renderer paints behind code.
  module CodeHighlighter
    # Rouge is required lazily so a `require 'przn'` doesn't pull in
    # the full 200-language lexer tree at startup for decks that don't
    # use fenced code blocks at all.
    @loaded = false

    # Mapping from Rouge token qualnames to ANSI color names (resolved
    # through Parser::NAMED_COLORS by the renderer's `color_code`).
    # Lookups walk up the dotted hierarchy — `Literal.String.Single`
    # falls back to `Literal.String`, then `Literal`, before giving up.
    TOKEN_COLORS = {
      'Keyword'                    => 'cyan',
      'Keyword.Constant'           => 'magenta',
      'Keyword.Declaration'        => 'cyan',
      'Keyword.Namespace'          => 'cyan',
      'Keyword.Pseudo'             => 'cyan',
      'Keyword.Reserved'           => 'cyan',
      'Keyword.Type'               => 'yellow',
      'Name.Builtin'               => 'cyan',
      'Name.Builtin.Pseudo'        => 'magenta',
      'Name.Class'                 => 'yellow',
      'Name.Constant'              => 'yellow',
      'Name.Decorator'             => 'magenta',
      'Name.Exception'             => 'yellow',
      'Name.Function'              => 'green',
      'Name.Function.Magic'        => 'magenta',
      'Name.Namespace'             => 'yellow',
      'Name.Tag'                   => 'cyan',
      'Name.Variable.Class'        => 'yellow',
      'Name.Variable.Global'       => 'red',
      'Name.Variable.Instance'     => 'red',
      'Literal.String'             => 'green',
      'Literal.String.Doc'         => 'green',
      'Literal.String.Symbol'      => 'yellow',
      'Literal.String.Regex'       => 'magenta',
      'Literal.String.Escape'      => 'magenta',
      'Literal.String.Interpol'    => 'yellow',
      'Literal.Number'             => 'magenta',
      'Comment'                    => 'bright_black',
      'Operator'                   => 'red',
      'Operator.Word'              => 'cyan'
    }.freeze

    module_function

    # Tokenize `code` with the Rouge lexer for `language` and return an
    # array of `[color_or_nil, value_string]` token pairs in source
    # order. `nil` color means "use the default foreground". Returns
    # nil if Rouge isn't available, the language is unknown, or
    # `language` is blank — in any of those cases the renderer falls
    # back to its plain-text path.
    def highlight(code, language)
      return nil if code.nil? || language.nil? || language.empty?
      load_rouge
      return nil unless @loaded
      lexer = Rouge::Lexer.find(language.to_s.downcase)
      return nil unless lexer

      tokens = []
      lexer.lex(code) { |tok, val| tokens << [color_for(tok), val] }
      tokens
    rescue StandardError
      # A lexer crash shouldn't kill the slide — fall back to plain.
      nil
    end

    # Walk a token's qualname up the dotted hierarchy looking for a
    # match in TOKEN_COLORS. `Literal.String.Single` → looks for
    # `Literal.String.Single`, then `Literal.String`, then `Literal`,
    # then gives up. Returns nil → caller renders the value in the
    # default fg.
    def color_for(token)
      name = token.qualname
      while name && !name.empty?
        return TOKEN_COLORS[name] if TOKEN_COLORS.key?(name)
        i = name.rindex('.')
        return nil unless i
        name = name[0, i]
      end
      nil
    end

    def load_rouge
      return if @loaded
      begin
        require 'rouge'
        @loaded = true
      rescue LoadError
        @loaded = false
      end
    end
  end
end
