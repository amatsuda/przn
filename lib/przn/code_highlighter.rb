# frozen_string_literal: true

module Przn
  # Tokenizer wrapper around Rouge for fenced code blocks. Maps Rouge's
  # token tree to either a hand-tuned ANSI-name palette (the default —
  # picks up the user's terminal colour theme so code reads naturally
  # against light or dark backgrounds), or to a named Rouge theme like
  # `monokai` / `gruvbox` / `github.dark` whose styles return absolute
  # `#RRGGBB` colours. The choice rides on `theme.code.highlight` in
  # theme.yml; unset keeps the ANSI palette.
  module CodeHighlighter
    # Rouge is required lazily so a `require 'przn'` doesn't pull in
    # the full 200-language lexer tree at startup for decks that don't
    # use fenced code blocks at all.
    @loaded = false

    # Memoized tokenization keyed by `[code, language]`. Warmed in the
    # background by `Renderer#preload` so that by the time the user
    # navigates to a slide, its fenced blocks are already tokenized —
    # the first visit is now as fast as the second. Cache entries are
    # small (a few KB per block) and never invalidated; the keys
    # change automatically when slide content changes.
    @cache = {}
    @cache_mutex = Mutex.new

    # Memoised Rouge::Theme instances keyed by name. `Rouge::Theme.find`
    # is cheap but `.new` allocates per call; one instance per theme is
    # plenty since `style_for` is pure. Returns nil for unknown names —
    # caller falls through to TOKEN_COLORS, matching the same
    # silent-fallback philosophy as an unknown lexer.
    @rouge_theme_cache = {}
    @rouge_theme_mutex = Mutex.new

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
    #
    # `theme:` picks the colour mapping. `nil` (the default) walks the
    # built-in ANSI-name TOKEN_COLORS table. A string like `"monokai"` /
    # `"gruvbox"` / `"github.dark"` resolves to a Rouge theme and uses
    # its per-token `#RRGGBB` styles instead. Unknown theme names
    # silently fall through to TOKEN_COLORS.
    def highlight(code, language, theme: nil)
      return nil if code.nil? || language.nil? || language.empty?
      lang = language.to_s.downcase
      # Theme rides in the cache key so two themes can coexist for the
      # same `[code, lang]` without trampling each other.
      key = [code, lang, theme]
      cached = @cache_mutex.synchronize { @cache[key] }
      return cached if cached

      load_rouge
      return nil unless @loaded
      lexer = Rouge::Lexer.find(lang)
      return nil unless lexer

      rouge_theme = theme && resolve_rouge_theme(theme)

      tokens = []
      lexer.lex(code) { |tok, val| tokens << [color_for(tok, rouge_theme), val] }
      @cache_mutex.synchronize { @cache[key] = tokens }
      tokens
    rescue StandardError
      # A lexer crash shouldn't kill the slide — fall back to plain.
      nil
    end

    # Resolve a Rouge theme name to a memoised theme instance.
    # `Rouge::Theme.find` returns the theme CLASS (or nil); we `.new`
    # it once and reuse. Anything Rouge doesn't recognise (typos,
    # retired names, garbage) returns nil and the caller falls back
    # to TOKEN_COLORS.
    def resolve_rouge_theme(name)
      cached = @rouge_theme_mutex.synchronize { @rouge_theme_cache[name] }
      return cached if cached
      return nil if @rouge_theme_mutex.synchronize { @rouge_theme_cache.key?(name) }

      klass = Rouge::Theme.find(name.to_s)
      instance = klass && klass.new
      @rouge_theme_mutex.synchronize { @rouge_theme_cache[name] = instance }
      instance
    rescue StandardError
      nil
    end

    # Resolve a token's colour. With a Rouge theme, ask the theme for
    # its `style_for(token).fg` — a `#RRGGBB` string or nil. Without
    # one, walk the qualname up the dotted hierarchy through
    # TOKEN_COLORS: `Literal.String.Single` → `Literal.String` →
    # `Literal` → nil. nil means "use the default fg."
    def color_for(token, rouge_theme = nil)
      if rouge_theme
        style = rouge_theme.style_for(token)
        return style && style.fg
      end

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
