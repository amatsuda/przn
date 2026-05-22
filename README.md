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

### Extended-display presenter mode

```
przn --present your_slides.md
```

On a setup with a secondary display (projector / external monitor) and running inside [Echoes](https://github.com/amatsuda/echoes), `--present` auto-spawns an **audience window** on the second display showing the clean current slide, while the laptop pane becomes the **presenter view**:

- Current slide rendered as normal
- Speaker notes (`{::note}` / `<note>` markup) shown in a side strip — stripped from the audience view
- Next slide's title hint
- Elapsed-time clock (or, when `rabbit:` is themed, the runner-bar visualization)

If only one display is attached or Echoes isn't the host terminal, `--present` falls back to today's mirror mode with a one-line warning on stderr.

Implementation: the two `przn` processes coordinate over a Unix socket. The presenter forwards every slide navigation as a `goto` message; the audience renders and otherwise stays silent. Notes are not transmitted to the audience side.

### PDF export

Two flavors:

```
przn --export your_slides.md                       # vector capture (default)
przn --export pdf your_slides.md
przn --export pdf -o output.pdf your_slides.md

przn --export prawn your_slides.md                 # Prawn (headless fallback)
przn --export prawn -o output.pdf your_slides.md
```

**`--export pdf`** (default) drives the live renderer for each slide and asks the terminal to save the rendered pane as a one-page **vector PDF**, then concatenates the per-slide PDFs into a single multi-page PDF. Output is an exact match of what's on screen — gradients, proportional fonts, OSC 66 sized text, custom bullets, all show up exactly as you'd see them — but vector, so the file stays small, scales infinitely, and text remains selectable. Requires running inside a terminal that implements the OSC 7772 `capture` command to a `.pdf` path (currently [Echoes](https://github.com/amatsuda/echoes)). The slides flicker through the visible pane during export.

**`--export prawn`** is the headless fallback: it renders the deck directly into a vector PDF via Prawn, without touching the terminal. Useful for CI or environments where Echoes isn't available, but diverges from the on-screen rendering for any feature the live renderer adds (OSC 66 sized text, OSC 7772 backgrounds, proportional fonts). Requires a TrueType font (with `glyf` outlines) for proper rendering — Prawn does not support CFF-based fonts (most `.otf` files). Fonts are auto-detected in this order: NotoSansJP TTF, HackGen, Arial Unicode.

### Key bindings

| Key | Action |
|-----|--------|
| `→` `↓` `l` `j` `Space` | Next slide |
| `←` `↑` `h` `k` | Previous slide |
| `g` | First slide |
| `G` | Last slide |
| `q` `Ctrl-C` | Quit |

### Selecting and copying text

`przn` doesn't capture mouse events, so drag-to-select and the terminal's own copy shortcut (Kitty: `Cmd+C` on macOS, `Ctrl+Shift+C` on Linux) work normally on a slide. Mouse-tracking modes that may have leaked from a previously crashed program are explicitly disabled on entry, so drag selection is reliable.

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

Long lines wrap at whitespace boundaries (not mid-word) for English-style text. A single word that's longer than the line — a URL, a class name — still wraps at the character it has to. CJK runs without inter-character whitespace fall back to per-character splitting.

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

### Absolute-position text

Place text at an arbitrary `(column, row)` on the slide, escaping the normal top-down paragraph flow:

```markdown
# Layout test

<at x="10" y="5">top-left ish</at>
<at x="40" y="15"><size=3>BIG</size></at>
<at x="80" y="25"><color=red>warn</color></at>
<at x="50%" y="50%">dead center</at>

{::at x="10" y="20"}same thing, kramdown form{:/at}
```

- `x` / `y` accept two forms:
  - **Plain integer** — 1-based terminal cells, matching the cursor-position escape (`\e[y;xH`). `x="1" y="1"` is the very top-left of the slide pane.
  - **Percent** (`x="50%"`, `y="100%"`) — resolves against the terminal's current width / height. Auto-adjusts when the pane is resized.
- Content is parsed inline, so all the usual styling works inside an `<at>` — `<size>`, `<color>`, `<font>`, `**bold**`, `*italic*`, etc.
- The block doesn't take up vertical space in the slide's layout — paragraphs around it render in their normal positions and the absolute placement layers on top. Useful for overlaying labels on a `<bg .../>` gradient or pinning annotations to specific cells.
- Out-of-range coordinates clamp into the visible area; missing / unparseable coordinates skip silently.

### Image

Embed an image with the standard markdown form, or the `<img>` XML form when you want to absolute-position it. Both produce identical output — `<img>` just opens the door to extra attributes like `x` / `y`.

```markdown
![](doge.png){:relative_height="70"}
<img src="doge.png" relative_height="70"/>

<img src="doge.png" x="5"   y="3"   relative_height="40"/>
<img src="doge.png" x="50%" y="50%" relative_height="40"/>
```

- `src` is required; `alt` and `title` are accepted and ignored at render time (kept for accessibility / future use).
- `relative_height="N"` caps the image at N % of the terminal height (default 70). Aspect ratio is preserved.
- `x` / `y` (optional) anchor the image's top-left at an absolute cell. Same two forms as [`<at>`](#absolute-position-text):
  - **Plain integer** — 1-based terminal cells.
  - **Percent** — resolves against the terminal's current width / height.
  - With `x` and `y` set, the image layers on top of the slide and contributes 0 to the layout flow — paragraphs around it render in their normal positions, exactly like `<at>`. Without `x` / `y`, the image stays horizontally centered and takes up its natural height in the flow.
- Rendering backend: Kitty Graphics Protocol on terminals that support it (PNG uploaded once and reused; JPG goes through `kitten icat`), Sixel as a fallback. Other terminals show nothing in place of the image.

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

Theme resolution:

1. **`theme.yml` in the deck's directory** — loaded automatically if present. No flag needed.
2. **`--theme path/to/your.yml`** — overrides step 1 with any other file you point to.
3. **`default_theme.yml`** (the file bundled with the gem) — used when neither of the above is found.

All keys are optional — anything you don't set falls back to the bundled defaults.

```yaml
font:
  family:                 # body text font; terminal: OSC 66 f=, PDF: Prawn font
  size: 18                # base PDF font size in pt
  color:                  # body text color; named ANSI or 6-digit hex

title:                    # h1 typography (slide titles)
  family:                 # font family
  size:                   # OSC 66 scale: numeric (1–7) or named (xx-small … xxxx-large); default x-large
  color:                  # named ANSI or 6-digit hex

bullet:                   # unordered-list marker; also h2–h6 prefix
  text: "・"              # the glyph
  size:                   # OSC 66 scale (1–7) for the bullet; default = body text's scale

background:               # default slide background (Echoes OSC 7772)
  color:                  # solid, e.g. "#1a1a2e"
  from:                   # gradient endpoint
  to:                     # gradient endpoint
  angle:                  # gradient angle in degrees

# rabbit:                 # opt into the 🐇 / 🐢 bottom progress indicator
#   duration: "30m"       # "1h30m", "1800s", or plain integer seconds; turtle hides when unset

colors:
  code_bg: "313244"
  dim: "6c7086"
  inline_code: "a6e3a1"
```

Notes:

- **`font.color`** — deck-wide default text color (terminal: ANSI fg; PDF: Prawn fg). Inline `<color=...>` / `<font color="...">` runs still win per-segment.
- **`bullet`** — `bullet.text` is the character; `bullet.size` is the OSC 66 scale used to render it. When `bullet.size` is smaller than the body text scale, the bullet is rendered with fractional scaling and vertical centering so it still aligns with the body line.
- **`font.family`** — applied to body text (terminal: via OSC 66 `f=`, requires Echoes; PDF: registered via fontconfig). Inline `<font face="...">` runs override it per-segment.
- **`title`** — h1 typography. Each attribute is independent from `font`: `title.family` does **not** inherit `font.family`, `title.color` does **not** inherit `font.color`. `title.size` defaults to x-large (OSC 66 `s=4`). When `title.family` is proportional, every h1 OSC 66 sequence is emitted with `h=2` so a terminal that honors centered horizontal alignment ([Echoes](https://github.com/amatsuda/echoes)) keeps the title visually centered against its reserved cell block. h2–h6 stay body text.
- **`background`** — the deck-wide default background. A per-slide `<bg .../>` directive overrides it for that slide. The Prawn fallback paints the PDF page in `background.color` when set; otherwise it leaves the page Prawn's default (white).
- **`rabbit`** — opt-in Rabbit-style bottom-row progress indicator. With the key absent, przn shows the simple `N / M` counter at the bottom-right. With the key present, the bottom row becomes: current slide # at the very left, total at the very right, 🐇 running between them tracking slide progress. Set `rabbit.duration` to also show 🐢 tracking elapsed time against the goal; without a duration the turtle stays hidden. Inside [Echoes](https://github.com/amatsuda/echoes) the emojis are emitted via OSC 7772 `;multicell` with `flip=h` so they face rightward; outside Echoes they fall back to standard OSC 66 and render unflipped (left-facing).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
