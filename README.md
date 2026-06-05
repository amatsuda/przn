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
- Elapsed-time clock (or, when `counter.duration` is set in the theme, the runner-bar visualization)

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
| `r` | Reload the deck (and `theme.yml`) from disk, keeping the current slide index |
| `q` `Ctrl-C` | Quit |

### Selecting and copying text

`przn` doesn't capture mouse events, so drag-to-select and the terminal's own copy shortcut (Kitty: `Cmd+C` on macOS, `Ctrl+Shift+C` on Linux) work normally on a slide. Mouse-tracking modes that may have leaked from a previously crashed program are explicitly disabled on entry, so drag selection is reliable.

## Markdown format

przn's Markdown format is compatible with [Rabbit](https://rabbit-shocker.org/)'s Markdown mode.

> **HTML-ish tag attributes** — every `<tag attr=value>` block below (`<bg>`, `<at>`, `<img>`, `<font>`) accepts three value forms: double-quoted `attr="value"`, single-quoted `attr='value'`, and unquoted `attr=value` (HTML5-ish — anything that isn't whitespace, `=`, `<`, `>`, a quote, or backtick). Self-closing tags need a space before `/>` when the last attribute is unquoted (`<img src=foo.png />`).

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

Fenced code blocks render on a dim gray background and are syntax-highlighted via [rouge](https://github.com/rouge-ruby/rouge) when a language is set on the fence — Ruby, Python, JavaScript, Go, Rust, HTML, JSON, YAML, shell, and ~200 others all work:

````markdown
```ruby
def hello
  puts "world"  # greet
end
```
````

Indented code blocks (4 spaces) with an optional kramdown IAL pick up highlighting too:

```markdown
    def hello
      puts "world"
    end
{: lang="ruby"}
```

Blocks without a language fall back to the same gray-on-dim plain text. The color scheme is fixed (tuned for the dim background) — comments dim, strings green, keywords cyan, numbers magenta, function / type names yellow / green.

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

Supported size names: `xx-small`, `x-small`, `small`, `large`, `x-large`, `xx-large`, `xxx-large`, `xxxx-large`, and numeric `1`-`7`.

```markdown
<size=x-large>Big text</size>
<size=7>Maximum size</size>
```

Rabbit-compatible kramdown form is also accepted: `{::tag name="x-large"}Big text{:/tag}`.

On [Kitty](https://sw.kovidgoyal.net/kitty/)-compatible terminals, sized text is rendered using the OSC 66 text sizing protocol. On other terminals, the markup is silently ignored.

### Color

Named ANSI colors (`red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, plus `bright_*` variants) and 6-digit hex.

```markdown
<color=red>warning</color>
<color=ff5555>custom hex</color>
```

For combined styling, the `color` attribute on `<font>` works too (see [Font](#font)). Rabbit-compatible kramdown form is also accepted: `{::tag name="red"}warning{:/tag}`.

### Font

HTML4-style `<font>` tag with `face`, `size`, and `color` attributes. Any subset, in any order.

```markdown
<font face="Helvetica Neue">Title</font>
<font face="Menlo" size="3">code</font>
<font face="Menlo" size="3" color="red">flagged</font>
```

Rabbit-compatible kramdown form is also accepted: `{::font name="Helvetica Neue"}Title{:/font}` (`name` maps to `face`).

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

Set a per-slide background — solid color, linear gradient, or image — via a self-closing block-level directive.

```markdown
# Title

<bg color="#1a1a2e"/>

content...

# Second slide

<bg from="#1a1a2e" to="#16213e" angle="90"/>

content...

# Third slide

<bg image="cover.png"/>

content layered on top of the image...
```

- `color` / `from` / `to` / `angle` use [Echoes](https://github.com/amatsuda/echoes)' OSC 7772 extension; other terminals ignore the escape sequence.
- `image` (PNG, path relative to the deck) uses the Kitty Graphics Protocol at `z: -1` so text and `<img>` content layer on top. Works on every kitty-graphics terminal (Kitty, Ghostty, Wezterm, Echoes…); silently no-ops elsewhere. `image` wins when set alongside `color` / `from` / `to`.
- For a deck-wide default, set `background.image:` (or `color:` / gradient keys) in `theme.yml`.

The previous slide's background — color, gradient, and image placement — is cleared on every navigation, and on `przn` exit, so your shell isn't left tinted or covered.

### Absolute-position text

Place text at an arbitrary `(column, row)` on the slide, escaping the normal top-down paragraph flow:

```markdown
# Layout test

<at x="10" y="5">top-left ish</at>
<at x="40" y="15"><size=3>BIG</size></at>
<at x="80" y="25"><color=red>warn</color></at>
<at x="50%" y="50%">dead center</at>
```

Rabbit-compatible kramdown form is also accepted: `{::at x="10" y="20"}content{:/at}`.

- `x` / `y` accept two forms:
  - **Plain integer** — 1-based terminal cells, matching the cursor-position escape (`\e[y;xH`). `x="1" y="1"` is the very top-left of the slide pane.
  - **Percent** (`x="50%"`, `y="100%"`) — resolves against the terminal's current width / height. Auto-adjusts when the pane is resized.
- Content is parsed inline, so all the usual styling works inside an `<at>` — `<size>`, `<color>`, `<font>`, `**bold**`, `*italic*`, etc.
- The block doesn't take up vertical space in the slide's layout — paragraphs around it render in their normal positions and the absolute placement layers on top. Useful for overlaying labels on a `<bg .../>` gradient or pinning annotations to specific cells.
- Out-of-range coordinates clamp into the visible area; missing / unparseable coordinates skip silently.

### Image

Embed an image with the standard markdown form, or the `<img>` XML form when you want to absolute-position it. Both produce identical output — `<img>` just opens the door to extra attributes like `x` / `y`.

```markdown
![](ruby.png)
<img src="ruby.png"/>

<img src="ruby.png" relative_height="70"/>
<img src="ruby.png" x="5"   y="3"   relative_height="40"/>
<img src="ruby.png" x="50%" y="50%" height="40%"/>
```

- `src` is required; `alt` and `title` are accepted and ignored at render time (kept for accessibility / future use).
- By default the image renders at its **intrinsic size** — no auto-shrink to fit. If it's bigger than the visible pane, the overflowing edge is clipped (same as a tall list of paragraphs scrolling off the bottom).
- `relative_height="N"` caps the image at N % of the terminal height (no default — without it, intrinsic size). Aspect ratio is preserved. `relative_width="N"` is the same for the horizontal dimension. Caps shrink, never grow.
- `height="N%"` / `width="N%"` are short-form aliases for `relative_height` / `relative_width` (both forms — `<img>` and `![]{:...}` — accept the alias). An explicit `relative_*` on the same block wins.
- `height="N"` / `width="N"` (plain integer, with optional `px` suffix) target an exact pixel size on that axis — aspect ratio is preserved, and the other axis is derived from it. Unlike the `relative_*` caps, pixel values can scale the image **up** past intrinsic size as well as down. Setting both pixel attrs fits the image inside the smaller of the two scales. `relative_*` caps still apply on top of a pixel target (`width="500" relative_width="40"` shrinks the 500-pixel result if it would exceed 40 % of the terminal).
- `x` / `y` (optional) anchor the image's top-left at an absolute cell. Same two forms as [`<at>`](#absolute-position-text):
  - **Plain integer** — 1-based terminal cells.
  - **Percent** — resolves against the terminal's current width / height.
  - **Either / both axes pin** — setting `x` only pins the horizontal column (vertical falls back to the flow row); setting `y` only pins the row (horizontal falls back to the centered flow position); setting both pins both. As soon as either is set, the image contributes 0 to the layout flow — paragraphs around it render in their normal positions, exactly like `<at>`. With neither `x` nor `y`, the image stays horizontally centered and takes up its natural height in the flow.
- **Z-order**: `z="N"` lets you put the image above or below cell text. A pinned `<img x y/>` defaults to `z="-1"` (behind text) so paragraphs and headings layered on the same cells stay readable; flow `<img>` (no `x` / `y`) stays at the Kitty default of `z=0` (on top of cells) because that's almost always what a standalone image wants. Pass `z="0"` / `z="1"` etc. to put a pinned image on top.
- Rendering backend: Kitty Graphics Protocol on terminals that support it (PNG uploaded once and reused; JPG goes through `kitten icat`), Sixel as a fallback. Other terminals show nothing in place of the image.

### Shapes and Lines

Keynote-style vector shapes — `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polyline>`, `<polygon>`, `<arrow>`, `<path>` — drawn natively by the terminal. Each tag is self-closing, absolute-positioned (contributes 0 to the layout flow), and accepts geometry attrs in slide cells or `N%` of the terminal width / height.

```markdown
<line   x1="10" y1="5"  x2="70" y2="5"  stroke="white" stroke-width="0.3"/>
<arrow  x1="10" y1="10" x2="70" y2="10" stroke="cyan"  stroke-width="0.5"/>
<rect   x="10" y="13" width="20" height="6" rx="1" fill="tomato"/>
<circle cx="50%" cy="15" r="5" fill="cyan"/>
<ellipse cx="50" cy="15" rx="20" ry="6" fill="none" stroke="gold" stroke-width="0.5"/>
<polyline points="10,5 30,15 50,5 70,15" stroke="lime" stroke-width="0.4"/>
<polygon points="50,2 60,15 40,15" fill="gold"/>
<path d="M 10 20 C 30 12 50 12 70 20" stroke="orange" stroke-width="0.4"/>
```

- Geometry attrs per shape:
  - `<rect>`: `x`, `y`, `width`, `height`, optional `rx`, `ry` for rounded corners.
  - `<circle>`: `cx`, `cy`, `r` (radius is a length, resolved against terminal width when given as `N%`).
  - `<ellipse>`: `cx`, `cy`, `rx`, `ry`.
  - `<line>`, `<arrow>`: `x1`, `y1`, `x2`, `y2`. The arrow grows a filled triangular head at `(x2, y2)`; the head sizes scale with `stroke-width` (length 4×, width 3×). The head's color defaults to `stroke`; an explicit `fill="..."` recolors only the head (handy for two-tone arrows).
  - `<polyline>` / `<polygon>`: `points="x1,y1 x2,y2 ..."` (space- or comma-separated; each coord can be `N%`).
  - `<path>`: `d="..."` — SVG path data using `M / L / H / V / C / S / Q / T / A / Z` commands (uppercase = absolute, lowercase = relative). Coordinates are in slide cells exactly like every other shape (`<path d="M 10 5 L 70 5"/>` runs a line from cell `(10, 5)` to `(70, 5)`); under the hood the renderer rewrites `d` into pixel coords so the stroke renders crisply at the cell aspect ratio. Percents inside `d` aren't supported (only plain numbers); the bbox is computed from every endpoint and control point in `d`, which slightly over-estimates curves (control points often sit outside the visible curve) — safe but means the placement reserves a few extra cells in that direction.
- Paint attrs pass through to SVG verbatim: `fill`, `stroke`, `stroke-width`, `opacity`, `fill-opacity`, `stroke-opacity`, `stroke-linecap`, `stroke-linejoin`, `stroke-dasharray`, `stroke-miterlimit`, `fill-rule`, `transform`.
- Colors: the full 147-name CSS / SVG color set is supported — `red`, `tomato`, `gold`, `lavender`, `rebeccapurple`, etc. The renderer expands every named color to `#rrggbb` before shipping the SVG, so Echoes' built-in named-color list (which is smaller) doesn't matter. Hex codes (`#rrggbb` / `#rgb`) and `rgb(...)` / `rgba(...)` pass through unchanged; `none`, `currentColor`, `transparent` work too.
- Defaults: closed shapes (`rect`, `circle`, `ellipse`, `polygon`) fill `white`; open shapes (`line`, `polyline`, `arrow`, `path`) stroke `white` at `stroke-width="0.2"` (a cell-width hairline). Override via explicit `fill=` / `stroke=` when your slide background is light. `<path>` can be either open (default) or closed via `Z` plus an explicit `fill="..."`.
- Coordinate semantics: positional attrs (`x`, `y`, `cx`, `cy`, `x1`, `y1`, `x2`, `y2`, `points`) are 1-indexed slide cells, matching `<at>` and `<img>` (so `x="10" y="5"` lands at column 10, row 5). Size attrs (`width`, `height`, `rx`, `ry`) are cell counts on the respective axis. The shape is composed in pixel coords behind the scenes using the terminal's actual cell pixel size, so a `circle r="5"` renders as a true circle even though terminal cells are typically ~1:2 wide-to-tall.
- Stroke widths are in **cell-widths** (typically ~12 px each) — `stroke-width="0.3"` is roughly a 3–4 pixel hairline regardless of cell aspect.
- Stroke is rendered inside the shape's padded bounding box, so the stroke won't get clipped.
- Z-order: shapes are registered **before** any text in the slide so that subsequent text writes re-fill the cell buffer at the cells the placement overlapped. Where the SVG is transparent (e.g., outside a thin `<line>` stroke or an unfilled outline), text shows through; where the SVG is opaque (a `<rect fill="..."/>`, a filled `<circle>`, etc.) the shape still covers any text underneath. Note: stock Echoes (today) ignores the `z=` parameter and always draws placements on top of cells — until z-index support lands upstream, solid-filled shapes that overlap text cells will occlude that text. `z="N"` is still accepted on the tag for forward compatibility.
- Rendering backend: Kitty Graphics Protocol direct-data mode. Echoes content-sniffs the payload and rasterizes via its native CoreGraphics fast path (sub-millisecond, synchronous) — these shapes always hit the fast path. On terminals that don't speak Kitty graphics the shape silently renders nothing.

### Slide layouts

Layouts let a slide carve itself into named regions ("slots") — title across the top, two columns underneath, image-and-caption side-by-side, etc. Without a layout, slides render in the existing top-down flow (the default behavior is unchanged).

**Picking a layout.** Use an h1 IAL with the layout name. Three interchangeable spellings:

```markdown
# Two columns {layout=two-column}     ← plain HTML-attr style
# Two columns {:layout=two-column}    ← kramdown IAL marker
# Two columns {layout: two-column}    ← YAML / JSON flow style
```

`=` and `:` are interchangeable separators. Values may be unquoted (`name`), single-quoted (`'name'`), or double-quoted (`"name"`).

**Filling slots.** The layout's first `title` slot is auto-filled from the h1. Remaining slots fill in declaration order; a block-level `<slot/>` advances to the next slot, and `<slot name="right"/>` jumps to a specific slot by name.

```markdown
# Two columns {layout=two-column}

left column content
- bullet A
- bullet B

<slot/>

right column content
- bullet C
- bullet D
```

**Defining layouts.** Layouts live under the `layouts:` key in `theme.yml`. Each layout's value is an ordered list of slots; each slot has `name`, `x`, `y`, `width`, `height`, and optional styling: `align` (`left` / `center` / `right`, default `left`), `size` (OSC 66 scale: `1`-`7` or named `xx-small` … `xxxx-large`), `family` (font family — Echoes), and `color` (named ANSI or 6-digit hex). Coordinates use the same convention as `<at>` and `<img x y>`: 1-based cells or `N%` of the terminal dimension. `%` values reflow on terminal resize.

```yaml
layouts:
  title-content:
    - {name: title,   x: 5, y: 3,  width: 90%, height: 6, align: center}
    - {name: content, x: 5, y: 10, width: 90%, height: 80%}
  cover:
    - {name: title,    x: 1, y: 35%, width: 100%, height: 25%, align: center, size: xxx-large}
    - {name: subtitle, x: 1, y: 80%, width: 100%, height: 15%, align: center, color: dim}
  two-column:
    - {name: title, x: 5,   y: 3,  width: 90%, height: 6, align: center}
    - {name: left,  x: 5,   y: 10, width: 45%, height: 80%}
    - {name: right, x: 50%, y: 10, width: 45%, height: 80%}
```

`align: center` on a slot is what makes h1 titles (and any other content in that slot) horizontally centered — there's no implicit "h1 always centers" magic. Per-block `<center>` / `{:.center}` directives and inline tags (`<size>`, `<font>`, `<color>`) still override the slot's defaults per-segment.

**Built-in layouts** (shipped in `default_theme.yml`):

- `default` — theme-wide fallback for slides without an `{layout=...}` IAL. Shipped identical to `title-content`: centered title band across the top, content below. Override in your own `theme.yml` to give every plain slide a different layout.
- `cover` — auto-applied to slide 0 when it has no `{layout=...}` IAL. Roughly emulates Keynote's "Title" slide: heading centered near the middle (slot `title`, y=35%), a smaller subtitle near the bottom (slot `subtitle`, y=80%). Put the deck title in the h1 and any author/date line in a paragraph after it.
- `title-only` — one slot, vertically centered. For section dividers.
- `takahashi` — [Takahashi-method](https://en.wikipedia.org/wiki/Takahashi_method) (高橋メソッド) slides: a single very-large phrase per slide, no decoration. Just the words.
- `title-content` — title across the top, content below.
- `two-column` — title across the top, two side-by-side columns.
- `photo-caption` — title across the top, image on the left, caption on the right.

Both `default` and `cover` are picked automatically when no IAL is set; `cover` only on slide 0, `default` everywhere else. To opt out of `cover` on slide 0, write `# Title {layout=default}` (or any other explicit layout) on the first slide. To remove the auto-cover behavior deck-wide, delete `cover` from your theme.

**Theme-wide default.** Override `layouts.default` in your own `theme.yml` to apply a different layout to every plain slide. For example, a full-bleed single-slot layout instead of the shipped title-band default:

```yaml
layouts:
  default:
    - {name: content, x: 1, y: 2, width: 100%, height: 100%}
```

A single slide can opt back out of the `default` layout with `{layout=none}`:

```markdown
# This one uses flow rendering {layout=none}

normal top-down content, no slot routing.
```

**Overflow.** Content past a slot's `height` spills downward; there's no clipping or shrink-to-fit. Slot height is a layout guide, not a hard cap — easier to debug while authoring. If you need tighter control, shrink the content or grow the slot.

### Comments

HTML-style comments — single-line or multi-line — are stripped at parse time.

```markdown
<!-- single-line note to self, hidden from the deck -->

<!--
multi-line
hidden block
-->
```

Rabbit-compatible kramdown form is also accepted:

```markdown
{::comment}
This text is hidden from the presentation.
{:/comment}
```

### Notes

```markdown
Visible text <note>(speaker note)</note>
```

Rabbit-compatible kramdown form is also accepted: `{::note}(speaker note){:/note}`.

### Escaping `<`, `>`, `&`

To show literal markup characters that would otherwise be interpreted as a tag, use HTML-style entity references:

```markdown
&lt;note&gt;            renders as: <note>
2 &lt; 3                renders as: 2 < 3
A &amp; B               renders as: A & B
```

A bare `<` not followed by a recognized tag name renders literally as well, so most accidental `<` characters are fine. The entities are only needed when you'd otherwise hit one of the tag patterns (`<size=...>`, `<color=...>`, `<font ...>`, `<note>`, `<wait/>`, `<br>`, `<center>`, `<right>`, `<at ...>`, `<bg .../>`, `<img .../>`, shape tags like `<rect/>` / `<circle/>`, or `<!-- ... -->`).

### Wait marker

Self-closing presentation flow marker, consumed at parse time:

```markdown
<wait/>
```

Rabbit-compatible kramdown form is also accepted: `{::wait/}`.

### Line break

Force a line break inside a paragraph with `<br>`, `<br/>`, or `<br />`. Each break closes the current line — surrounding inline styling (`<color>`, `<font>`, `<center>`, etc.) carries across, so a centered paragraph with explicit breaks stays centered on every line. Two `<br>`s in a row insert a blank line between the chunks.

```markdown
<center>title in the middle<br>subtitle on the next line</center>

first line<br><br>second line, after a blank
```

Paragraphs that would overflow the slide width wrap automatically — `<br>` is only for the cases where you want a break at a specific spot.

## Theming

Theme resolution:

1. **`theme.yml` in the deck's directory** — loaded automatically if present. No flag needed.
2. **`--theme path/to/your.yml`** — overrides step 1 with any other file you point to.
3. **`default_theme.yml`** (the file bundled with the gem) — used when neither of the above is found.

All keys are optional — anything you don't set falls back to the bundled defaults.

```yaml
font:                     # body text typography (paragraphs, lists, h2–h6, code, tables, …)
  family:                 # font family; terminal: OSC 66 f= (requires Echoes)
  size:                   # OSC 66 scale: numeric (1–7) or named (xx-small … xxxx-large); default 2 (small)
  color:                  # named ANSI or 6-digit hex; falls back to terminal default fg when unset

title:                    # h1 typography (slide titles)
  family:                 # font family
  size:                   # OSC 66 scale: numeric (1–7) or named (xx-small … xxxx-large); default x-large
  color:                  # named ANSI or 6-digit hex

bullet:                   # unordered-list marker; also h2–h6 prefix
  text: "・"              # the glyph
  size:                   # OSC 66 scale (1–7) for the bullet; default = body text's scale
  color:                  # named ANSI or 6-digit hex; falls back to body text color when unset

background:               # default slide background (Echoes OSC 7772)
  color:                  # solid, e.g. "#1a1a2e"
  from:                   # gradient endpoint
  to:                     # gradient endpoint
  angle:                  # gradient angle in degrees

counter:                  # bottom-of-screen slide counter; runner-bar opt-in via duration
  color:                  # named ANSI or 6-digit hex; default = dim
  duration:               # "30m", "1h30m", "1800s", or plain integer seconds; opt in to the 🐇/🐢 runner bar

colors:
  code_bg: "313244"
  dim: "6c7086"
  inline_code: "a6e3a1"
```

Notes:

- **`font`** — body text typography for everything that isn't an h1: paragraphs, lists, h2–h6, blockquotes, code blocks, tables, definition lists. Mirrors `title`'s three knobs:
  - **`font.family`** — applied via OSC 66 `f=` (requires Echoes); PDF: registered via fontconfig. Inline `<font face="...">` runs override it per-segment.
  - **`font.size`** — OSC 66 scale; controls the visual size of body text (numeric `1`–`7` or named `xx-small` … `xxxx-large`). Default `2` (small). Inline `<size=...>` runs override it per-segment.
  - **`font.color`** — deck-wide default text color. Inline `<color=...>` / `<font color="...">` runs still win per-segment.
- **`bullet`** — `bullet.text` is the character; `bullet.size` is the OSC 66 scale used to render it. When `bullet.size` is smaller than the body text scale, the bullet is rendered with fractional scaling and vertical centering so it still aligns with the body line. `bullet.color` sets a dedicated foreground color for the marker (named ANSI or 6-digit hex); when unset, the bullet inherits the body text color.
- **`title`** — h1 typography. Same three knobs as `font` (`family`, `size`, `color`) but each is independent: `title.family` does **not** inherit `font.family`, `title.color` does **not** inherit `font.color`. `title.size` defaults to x-large (OSC 66 `s=4`). When `title.family` is proportional, every h1 OSC 66 sequence is emitted with `h=2` so a terminal that honors centered horizontal alignment ([Echoes](https://github.com/amatsuda/echoes)) keeps the title visually centered against its reserved cell block. h2–h6 stay body text.
- **`background`** — the deck-wide default background. A per-slide `<bg .../>` directive overrides it for that slide. The Prawn fallback paints the PDF page in `background.color` when set; otherwise it leaves the page Prawn's default (white).
- **`counter`** — bottom-of-screen slide counter. Without `counter.duration`, przn shows a plain `N / M` counter at the bottom-right. Set `counter.duration` to opt into the Rabbit-style runner bar: current slide # at the very left, total at the very right, 🐇 running between them tracking slide progress and 🐢 tracking elapsed time against the goal. `counter.color` (named ANSI or 6-digit hex) styles both the plain counter and the runner-bar anchor numbers; default is dim ANSI. Inside [Echoes](https://github.com/amatsuda/echoes) the emojis are emitted via OSC 7772 `;multicell` with `flip=h` so they face rightward; outside Echoes they fall back to standard OSC 66 and render unflipped (left-facing).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
