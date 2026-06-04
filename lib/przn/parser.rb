# frozen_string_literal: true

require 'strscan'

module Przn
  module Parser
    # Size names → Kitty text sizing scale (1-7)
    SIZE_SCALES = {
      'xx-small' => 1,
      'x-small'  => 1,
      'small'    => 2,
      'large'    => 3,
      'x-large'  => 4,
      'xx-large' => 5,
      'xxx-large' => 6,
      'xxxx-large' => 7,
      '1' => 1, '2' => 2, '3' => 3, '4' => 4, '5' => 5, '6' => 6, '7' => 7
    }.freeze

    NAMED_COLORS = {
      'black' => 30, 'red' => 31, 'green' => 32, 'yellow' => 33,
      'blue' => 34, 'magenta' => 35, 'cyan' => 36, 'white' => 37,
      'bright_black' => 90, 'bright_red' => 91, 'bright_green' => 92,
      'bright_yellow' => 93, 'bright_blue' => 94, 'bright_magenta' => 95,
      'bright_cyan' => 96, 'bright_white' => 97
    }.freeze

    # HTML-ish attribute, three accepted value forms:
    #   key="value"   key='value'   key=bareword
    # The unquoted token excludes whitespace, `=`, `<`, `>`, `"`, `'` and
    # backtick, matching the spirit of HTML5's unquoted-attribute grammar.
    # `/` is intentionally NOT excluded so paths like `src=path/to/file`
    # work — which means self-closing tags need a space before `/>` when
    # the last attribute is unquoted (`<img src=foo.png />`).
    ATTR_RE_SRC = '[\w-]+=(?:"[^"]*"|\'[^\']*\'|[^\s=<>"\'`]+)'

    module_function

    def parse(markdown)
      slides = split_slides(markdown)
      Presentation.new(slides.map { |raw| parse_slide(raw) })
    end

    # Split on h1 headings (Rabbit-compatible)
    def split_slides(markdown)
      chunks = []
      current = +''
      in_fence = false

      markdown.each_line do |line|
        if line.match?(/\A\s*```/)
          in_fence = !in_fence
          current << line
        elsif !in_fence && line.match?(/\A#\s/)
          chunks << current unless current.strip.empty?
          current = +line
        else
          current << line
        end
      end
      chunks << current unless current.strip.empty?
      chunks
    end

    def parse_slide(raw)
      blocks = []
      slide_attrs = {}
      lines = raw.lines
      i = 0

      while i < lines.size
        line = lines[i]

        case line
        # <!-- ... --> block (single or multi line) — skip entirely.
        # Sibling of the kramdown `{::comment} ... {:/comment}` form.
        when /\A\s*<!--/
          # Same line? Skip just this line.
          i += 1 unless line.match?(/-->/)
          i += 1 while i < lines.size && !lines[i].match?(/-->/)

        # {::comment} ... {:/comment} block — skip entirely
        when /\A\s*\{::comment\}/
          i += 1
          i += 1 while i < lines.size && !lines[i].match?(/\{:\/comment\}/)

        # Block alignment: {:.center} or {:.right}
        when /\A\s*\{:\.(\w+)\}\s*\z/
          blocks << {type: :align, align: Regexp.last_match(1).to_sym}

        # Block alignment, XML form: <center>content</center> or <right>content</right>
        when /\A\s*<(center|right)>(.*)<\/\1>\s*\z/
          blocks << {type: :align, align: Regexp.last_match(1).to_sym}
          blocks << {type: :paragraph, content: Regexp.last_match(2)}

        # Slide background (Echoes OSC 7772):
        #   <bg color="#..."/>                              — solid (bg-color)
        #   <bg from="#..." to="#..." angle="N"/>           — linear gradient (bg-gradient)
        # Attribute values may be double-quoted, single-quoted, or
        # unquoted (HTML5-ish — see ATTR_RE_SRC).
        when %r{\A\s*<bg((?:\s+#{ATTR_RE_SRC})*)\s*/>\s*\z}o
          blocks << {type: :bg, attrs: parse_xml_attrs(Regexp.last_match(1))}

        # Absolute-position text:
        #   <at x="N" y="N">content</at>
        #   {::at x="N" y="N"}content{:/at}
        # Content can include inline markup (size, color, font, bold, …).
        when %r{\A\s*<at((?:\s+#{ATTR_RE_SRC})+)\s*>(.*)</at>\s*\z}o
          blocks << {type: :at, attrs: parse_xml_attrs(Regexp.last_match(1)), content: Regexp.last_match(2)}
        when %r{\A\s*\{::at((?:\s+#{ATTR_RE_SRC})+)\}(.*)\{:/at\}\s*\z}o
          blocks << {type: :at, attrs: parse_xml_attrs(Regexp.last_match(1)), content: Regexp.last_match(2)}

        # Fenced code block
        when /\A\s*```(\w*)\s*\z/
          lang = Regexp.last_match(1)
          lang = nil if lang.empty?
          code_lines = []
          i += 1
          while i < lines.size && !lines[i].match?(/\A\s*```\s*\z/)
            code_lines << lines[i]
            i += 1
          end
          # Check for kramdown IAL on next line: {: lang="ruby"}
          if (i + 1) < lines.size && lines[i + 1]&.match?(/\A\s*\{:/)
            i += 1
            if lines[i].match(/lang="(\w+)"/)
              lang = Regexp.last_match(1)
            end
          end
          blocks << {type: :code_block, content: code_lines.join, language: lang}

        # Indented code block (4 spaces)
        when /\A {4}(.*)$/
          code_lines = [Regexp.last_match(1)]
          while (i + 1) < lines.size && lines[i + 1].match?(/\A {4}/)
            i += 1
            code_lines << lines[i].sub(/\A {4}/, '')
          end
          # Check for kramdown IAL: {: lang="ruby"}
          lang = nil
          if (i + 1) < lines.size && lines[i + 1]&.match?(/\A\s*\{:/)
            i += 1
            if lines[i].match(/lang="(\w+)"/)
              lang = Regexp.last_match(1)
            end
          end
          blocks << {type: :code_block, content: code_lines.join("\n") + "\n", language: lang}

        # h1 (slide title) — also accepts a trailing IAL with slide-level
        # metadata: `# Title {layout=name}` / `{:layout=name}` / `{layout: name}`.
        # The IAL is lifted off and stashed on slide_attrs; the heading
        # content keeps just the title text.
        when /\A#\s+(.*)/
          heading_body, ial_attrs = extract_h1_ial(Regexp.last_match(1).strip)
          blocks << {type: :heading, level: 1, content: heading_body}
          slide_attrs.merge!(ial_attrs)

        # Slot break inside a layout-driven slide. `<slot/>` advances to
        # the next slot; `<slot name="right"/>` jumps to that named slot.
        # Outside a layout, the block is a render-time no-op.
        when %r{\A\s*<slot((?:\s+#{ATTR_RE_SRC})*)\s*/>\s*\z}o
          attrs = parse_xml_attrs(Regexp.last_match(1))
          blocks << {type: :slot, name: attrs[:name]}

        # h2-h6 (sub-headings within slide)
        when /\A(\#{2,6})\s+(.*)/
          level = Regexp.last_match(1).size
          text = Regexp.last_match(2).strip
          blocks << {type: :heading, level: level, content: text}

        # Block quote
        when /\A>\s?(.*)/
          quote_lines = [Regexp.last_match(1)]
          while (i + 1) < lines.size && (m = lines[i + 1].match(/\A>\s?(.*)/))
            i += 1
            quote_lines << m[1]
          end
          blocks << {type: :blockquote, content: quote_lines.join("\n")}

        # Table
        when /\A\|/
          table_lines = [line.strip]
          while (i + 1) < lines.size && lines[i + 1].match?(/\A\|/)
            i += 1
            table_lines << lines[i].strip
          end
          blocks << parse_table(table_lines)

        # Unordered list (* or - item)
        when /\A[*\-]\s+(.*)/
          items = []
          while i < lines.size && (lines[i].match?(/\A[*\-]\s+/) || lines[i].match?(/\A {2,}[*\-]\s+/) || lines[i].match?(/\A {2,}\S/))
            if lines[i].match(/\A(\s*)[*\-]\s+(.*)/)
              depth = Regexp.last_match(1).size / 2
              items << {text: Regexp.last_match(2), depth: depth}
            elsif lines[i].match(/\A {2,}(\S.*)/)
              # Continuation line
              items.last[:text] << ' ' << Regexp.last_match(1) if items.last
            else
              break
            end
            i += 1
          end
          i -= 1
          blocks << {type: :unordered_list, items: items}

        # Ordered list
        when /\A(\s*)\d+\.\s+(.*)/
          items = []
          while i < lines.size && lines[i].match?(/\A\s*\d+\.\s+/)
            lines[i].match(/\A(\s*)\d+\.\s+(.*)/)
            depth = Regexp.last_match(1).size / 3
            items << {text: Regexp.last_match(2), depth: depth}
            i += 1
          end
          i -= 1
          blocks << {type: :ordered_list, items: items}

        # Shape primitives — Keynote-style "Shapes and Lines". Each tag is
        # self-closing with the shape's geometry attrs (cells, or `N%` of
        # the terminal w/h) plus optional SVG paint attrs (fill, stroke,
        # stroke-width, opacity, …). The renderer composes each block into
        # a tiny self-contained SVG document shipped via the Kitty
        # Graphics Protocol — Echoes content-sniffs the payload and
        # rasterizes it through its native CoreGraphics fast path
        # (sub-millisecond for path-only SVGs, which these always are).
        when %r{\A\s*<(rect|circle|ellipse|line|polyline|polygon|arrow|path)((?:\s+#{ATTR_RE_SRC})*)\s*/>\s*\z}o
          kind = Regexp.last_match(1).to_sym
          attrs = parse_xml_attrs(Regexp.last_match(2)).transform_keys(&:to_s)
          blocks << {type: :shape, kind: kind, attrs: attrs}

        # Image, XML form: <img src="path" alt="..." title="..." {:attrs}/>
        # Equivalent to the markdown `![alt](src "title"){:attrs}` form below
        # — emits the same `:image` block so the renderer handles both
        # identically. `src` is required; all other attributes pass through
        # to `block[:attrs]` (string-keyed, matching markdown's IAL parse) so
        # `relative_height`, `width`, etc. work the same way.
        when %r{\A\s*<img((?:\s+#{ATTR_RE_SRC})+)\s*/>\s*\z}o
          raw = parse_xml_attrs(Regexp.last_match(1))
          path = raw.delete(:src)
          if path
            alt = raw.delete(:alt).to_s
            title = raw.delete(:title)
            attrs = raw.transform_keys(&:to_s)
            normalize_image_attrs!(attrs)
            blocks << {type: :image, path: path, alt: alt, title: title, attrs: attrs}
          end

        # Image: ![alt](path "title"){:attrs}
        when /\A!\[([^\]]*)\]\((\S+?)(?:\s+"([^"]*)")?\)(.*)/
          alt = Regexp.last_match(1)
          path = Regexp.last_match(2)
          title = Regexp.last_match(3)
          rest = Regexp.last_match(4).strip
          attrs = {}
          if rest.match(/\{([^}]+)\}/)
            parse_image_attrs(Regexp.last_match(1), attrs)
          elsif rest.match(/\{(.+)/) || ((i + 1) < lines.size && lines[i + 1]&.match?(/\A\s*\{/))
            attr_str = rest.sub(/\A\{:?\s*/, '')
            while !attr_str.include?('}') && (i + 1) < lines.size
              i += 1
              attr_str << ' ' << lines[i].strip
            end
            attr_str = attr_str.sub(/\}\s*\z/, '')
            parse_image_attrs(attr_str, attrs)
          end
          normalize_image_attrs!(attrs)
          blocks << {type: :image, path: path, alt: alt, title: title, attrs: attrs}

        # Definition list: term on one line, :   definition on next
        when /\A(\S.*)\s*\z/
          if (i + 1) < lines.size && lines[i + 1].match?(/\A:\s{3}/)
            term = Regexp.last_match(1).strip
            i += 1
            definition_lines = []
            while i < lines.size && lines[i].match?(/\A:\s{3}(.*)|\A {4}(.*)/)
              if lines[i].match(/\A:\s{3}(.*)/)
                definition_lines << Regexp.last_match(1)
              elsif lines[i].match(/\A {4}(.*)/)
                definition_lines << Regexp.last_match(1)
              end
              i += 1
            end
            i -= 1
            blocks << {type: :definition_list, term: term, definition: definition_lines.join("\n")}
          else
            blocks << {type: :paragraph, content: Regexp.last_match(1).strip}
          end

        when /\A\s*\z/
          blocks << {type: :blank}

        else
          blocks << {type: :paragraph, content: line.strip}
        end
        i += 1
      end

      layout = slide_attrs.delete(:layout)
      Slide.new(blocks, layout: layout, attrs: slide_attrs)
    end

    # Pull a trailing IAL block off an h1's content. Accepted spellings:
    #   `Title {layout=name}`     — plain HTML-attr style
    #   `Title {:layout=name}`    — kramdown IAL (leading colon marker)
    #   `Title {layout: name}`    — YAML / JSON flow style (colon separator)
    # `=` and `:` are interchangeable separators. Values can be unquoted,
    # single-quoted, or double-quoted; unquoted excludes `,` and `}` so
    # multi-attr forms like `{layout: two-column, foo: bar}` parse cleanly.
    # If no key=value pairs are found inside the braces we leave the title
    # untouched — `# What about {curlies}?` shouldn't be munched.
    def extract_h1_ial(content)
      return [content, {}] unless content =~ /\A(.*?)\s*\{([^}]*)\}\s*\z/
      body  = Regexp.last_match(1)
      inner = Regexp.last_match(2).sub(/\A:?\s*/, '')

      attrs = {}
      inner.scan(/(\w+)\s*[=:]\s*(?:"([^"]*)"|'([^']*)'|([^\s=:<>"',}]+))/) do |key, dq, sq, uq|
        attrs[key.to_sym] = dq || sq || uq
      end
      return [content, {}] if attrs.empty?
      [body, attrs]
    end

    # HTML4-style <font face="..." size="..." color="..."> attributes.
    # Kramdown's {::font name="..."} legacy spelling for the family is also
    # accepted and folded into :face so the renderer has one shape to handle.
    def parse_font_attrs(str)
      attrs = parse_xml_attrs(str)
      attrs[:face] = attrs.delete(:name) if attrs.key?(:name) && !attrs.key?(:face)
      attrs.slice(:face, :size, :color)
    end

    # Generic attribute scanner — three value forms accepted:
    #   key="value"   key='value'   key=bareword
    # Returns a hash with symbolized keys. Doesn't validate which keys
    # are allowed; callers slice.
    def parse_xml_attrs(str)
      attrs = {}
      str.scan(/([\w-]+)=(?:"([^"]*)"|'([^']*)'|([^\s=<>"'`]+))/) do |key, dq, sq, uq|
        attrs[key.to_sym] = dq || sq || uq
      end
      attrs
    end

    def parse_image_attrs(str, attrs)
      str = str.sub(/\A:?\s*/, '')
      str.scan(/([\w-]+)=['"]([^'"]*)['"]/) do |key, value|
        attrs[key.tr('-', '_')] = value
      end
    end

    # Rewrite `height="N%"` / `width="N%"` into the canonical
    # `relative_height="N"` / `relative_width="N"` the renderer reads.
    # Values without a `%` suffix pass through unchanged (and are
    # ignored downstream); an explicit `relative_*` already on the
    # block wins so authors can mix forms without surprise.
    def normalize_image_attrs!(attrs)
      if (h = attrs['height']) && (m = h.match(/\A(\d+)%\z/))
        attrs.delete('height')
        attrs['relative_height'] ||= m[1]
      end
      if (w = attrs['width']) && (m = w.match(/\A(\d+)%\z/))
        attrs.delete('width')
        attrs['relative_width'] ||= m[1]
      end
    end

    def parse_table(lines)
      rows = []
      lines.each do |line|
        next if line.match?(/\A\|[-|:\s]+\|\s*\z/)  # separator row

        cells = line.split('|').map(&:strip).reject(&:empty?)
        rows << cells
      end
      {type: :table, header: rows.first, rows: rows.drop(1)}
    end

    # Parse inline text with Rabbit-compatible markup
    def parse_inline(text)
      segments = []
      scanner = StringScanner.new(text)

      until scanner.eos?
        if scanner.scan(/<size=([^>\s]+)>(.*?)<\/size>/)
          segments << [:tag, scanner[2], scanner[1]]
        elsif scanner.scan(/<color=([^>\s]+)>(.*?)<\/color>/)
          segments << [:tag, scanner[2], scanner[1]]
        elsif scanner.scan(/\{::tag\s+name="([^"]+)"\}(.*?)\{:\/tag\}/)
          # Rabbit-compatible kramdown spelling; covers both size and color.
          segments << [:tag, scanner[2], scanner[1]]
        elsif scanner.scan(%r{<font((?:\s+#{ATTR_RE_SRC})+)\s*>(.*?)</font>}o)
          segments << [:font, scanner[2], parse_font_attrs(scanner[1])]
        elsif scanner.scan(%r{\{::font((?:\s+#{ATTR_RE_SRC})+)\}(.*?)\{:/font\}}o)
          segments << [:font, scanner[2], parse_font_attrs(scanner[1])]
        elsif scanner.scan(/<note>(.*?)<\/note>/)
          segments << [:note, scanner[1]]
        elsif scanner.scan(/\{::note\}(.*?)\{:\/note\}/)
          segments << [:note, scanner[1]]
        elsif scanner.scan(/<wait\s*\/>/) || scanner.scan('{::wait/}')
          # skip wait markers in inline text
        elsif scanner.scan('&lt;')
          segments << [:text, '<']
        elsif scanner.scan('&gt;')
          segments << [:text, '>']
        elsif scanner.scan('&amp;')
          segments << [:text, '&']
        elsif scanner.scan(/`([^`]+)`/)
          segments << [:code, scanner[1]]
        elsif scanner.scan(/\*\*(.+?)\*\*/)
          segments << [:bold, scanner[1]]
        elsif scanner.scan(/\*(.+?)\*/)
          segments << [:italic, scanner[1]]
        elsif scanner.scan(/~~(.+?)~~/)
          segments << [:strikethrough, scanner[1]]
        else
          segments << [:text, scanner.scan(/[^`*~{<&]+|./)]
        end
      end

      # Coalesce adjacent :text segments. The scanner has to bail to a
      # single-character `.` when it sees `&` so the `&lt;` / `&gt;` /
      # `&amp;` entity matches can run on the next iteration, which
      # leaves a bare `&` as its own segment and fragments the
      # surrounding text. Merging them back together means one OSC 66
      # multicell sequence per typeset run — important for h1 titles
      # under a proportional font, where Echoes pads each run
      # independently and stray segments become visible gaps.
      segments.each_with_object([]) do |seg, acc|
        if seg[0] == :text && acc.last && acc.last[0] == :text
          acc.last[1] = acc.last[1] + seg[1]
        else
          acc << seg
        end
      end
    end
  end
end
