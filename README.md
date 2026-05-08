# przn

A terminal-based presentation tool written in Ruby.
Renders Markdown slides with [Kitty text sizing protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/) support for beautifully scaled headings.

## Installation

```
gem install przn
```

## Usage

```
przn your_slides.md
```

To open the presentation directly at a specific slide, append `@N` (1-based):

```
przn your_slides.md @42
```

Out-of-range numbers are clamped to the last slide, so `@9999` jumps to the end.

### PDF export

```
przn --export your_slides.md
przn --export pdf your_slides.md
przn --export pdf -o output.pdf your_slides.md
```

Requires a TrueType font (with `glyf` outlines) for proper rendering. Prawn does not support CFF-based fonts (most `.otf` files). Fonts are auto-detected in this order: NotoSansJP TTF, HackGen, Arial Unicode.

### Key bindings

| Key | Action |
|-----|--------|
| `→` `↓` `l` `j` `Space` | Next slide |
| `←` `↑` `h` `k` | Previous slide |
| `g` | First slide |
| `G` | Last slide |
| `q` `Ctrl-C` | Quit |

## Markdown format

przn's Markdown format is compatible with [Rabbit](https://rabbit-shocker.org/)'s Markdown mode.

### Slide splitting

Slides are separated by `#` (h1) headings.

```markdown
# Slide 1

content

# Slide 2

more content
```

### Text formatting

```markdown
*emphasis*
**bold**
~~strikethrough~~
`inline code`
```

### Lists

```markdown
* item 1
* item 2
  * nested item

- also works as bullets

1. ordered
2. list
```

### Code blocks

Fenced code blocks:

````markdown
```ruby
puts "hello"
```
````

Indented code blocks (4 spaces) with optional kramdown IAL:

```markdown
    def hello
      puts "world"
    end
{: lang="ruby"}
```

### Block quotes

```markdown
> quoted text
> continues here
```

### Tables

```markdown
| Header 1 | Header 2 |
|----------|----------|
| cell 1   | cell 2   |
```

### Definition lists

```markdown
term
:   definition
```

### Text sizing

Uses Rabbit-compatible `{::tag}` notation. Supported size names: `xx-small`, `x-small`, `small`, `large`, `x-large`, `xx-large`, `xxx-large`, `xxxx-large`, and numeric `1`-`7`.

```markdown
{::tag name="x-large"}Big text{:/tag}
{::tag name="7"}Maximum size{:/tag}
```

An XML-style alternative is also accepted:

```markdown
<size=x-large>Big text</size>
<size=7>Maximum size</size>
```

On [Kitty](https://sw.kovidgoyal.net/kitty/)-compatible terminals, sized text is rendered using the OSC 66 text sizing protocol. On other terminals, the markup is silently ignored.

### Color

Named ANSI colors (`red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, plus `bright_*` variants) and 6-digit hex. Use `{::tag name="..."}` (kramdown form) or the `color` attribute on `<font>` (see [Font](#font)).

```markdown
{::tag name="red"}warning{:/tag}
{::tag name="ff5555"}custom hex{:/tag}

<font color="red">warning</font>
<font color="ff5555">custom hex</font>
```

### Font

HTML 4-style `<font>` tag with `face`, `size`, and `color` attributes. Any subset, in any order. The kramdown shape is also accepted.

```markdown
<font face="Helvetica Neue">Title</font>
<font face="Menlo" size="3">code</font>
<font face="Menlo" size="3" color="red">flagged</font>

{::font name="Helvetica Neue"}Title{:/font}
```

`face` requires a terminal that honors the OSC 66 `f=` extension (e.g. [Echoes](https://github.com/amatsuda/echoes)). For PDF export, the family is registered with Prawn via fontconfig — families that can't be found fall through to the default font.

### Alignment

```markdown
{:.center}
centered text

{:.right}
right-aligned text
```

XML form (single-line, paragraph-level):

```markdown
<center>centered <size=3>text</size></center>
<right>right-aligned</right>
```

### Slide background

Set a per-slide background — solid color or linear gradient — via a self-closing block-level directive. Uses the [Echoes](https://github.com/amatsuda/echoes) OSC 7772 extension; other terminals ignore the escape sequence.

```markdown
# Title

<bg color="#1a1a2e"/>

content...

# Second slide

<bg from="#1a1a2e" to="#16213e" angle="90"/>

content...
```

The previous slide's background is cleared on every navigation, and on `przn` exit, so your shell isn't left tinted.

### Comments

```markdown
{::comment}
This text is hidden from the presentation.
{:/comment}
```

### Notes

```markdown
Visible text {::note}(speaker note){:/note}
Visible text <note>(speaker note)</note>
```

### Escaping `<`, `>`, `&`

To show literal markup characters that would otherwise be interpreted as a tag, use HTML-style entity references:

```markdown
&lt;note&gt;            renders as: <note>
2 &lt; 3                renders as: 2 < 3
A &amp; B               renders as: A & B
```

A bare `<` not followed by a recognized tag name renders literally as well, so most accidental `<` characters are fine. The entities are only needed when you'd otherwise hit one of the tag patterns (`<size=...>`, `<font ...>`, `<note>`, `<wait/>`, `<center>`, `<right>`, `<bg .../>`).

### Wait marker

Self-closing presentation flow marker, consumed at parse time:

```markdown
{::wait/}
<wait/>
```

## Theming

Pass a YAML file via `--theme path/to/theme.yml`. All keys are optional — anything you don't set falls back to the defaults baked in at `default_theme.yml`.

```yaml
colors:
  background: "000000"
  foreground: "ffffff"
  heading:                # falls back to foreground
  code_bg: "313244"
  dim: "6c7086"
  inline_code: "a6e3a1"

font:
  family:                 # body text font; terminal: OSC 66 f=, PDF: Prawn font
  size: 18                # base PDF font size in pt

bullet: "・"              # unordered-list marker; also h2–h6 prefix
bullet_size:              # OSC 66 scale (1–7) for the bullet glyph

heading_face:             # font family for h1 (slide titles)

bg:                       # default slide background (Echoes OSC 7772)
  color:                  # solid, e.g. "#1a1a2e"
  from:                   # gradient endpoint
  to:                     # gradient endpoint
  angle:                  # gradient angle in degrees
```

Notes:

- **`bullet`** / **`bullet_size`** — `bullet` is the character; `bullet_size` is the OSC 66 scale used to render it. When smaller than the body text scale, the bullet is rendered with fractional scaling and vertical centering so it still aligns with the body line.
- **`font.family`** — applied to body text (terminal: via OSC 66 `f=`, requires Echoes; PDF: registered via fontconfig). Inline `<font face="...">` runs override it per-segment.
- **`heading_face`** — independent from `font.family`. h1 uses `heading_face` if set, else falls back to the terminal's default font (it does **not** silently inherit `font.family`). h2–h6 are body text.
- **`bg`** — the deck-wide default background. A per-slide `<bg .../>` directive overrides it for that slide.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
