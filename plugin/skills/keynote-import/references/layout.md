# przn layout rules

Based on the implementation in `lib/przn/renderer.rb` (`render_layout`, `render_heading`, `render_paragraph`, `render_unordered_list`) and on measurements taken in Echoes. The numbers are measured, so read the code when the behavior does not match.

## Contents

- The shape of theme.yml
- The shape of the deck
- Text size
- Horizontal position
- Vertical position
- Wrapping and running out of columns
- Aspect ratio
- What przn cannot do

## The shape of theme.yml

```yaml
font:
  family: HiraginoSans-W6
  size: 3
  color: "#231916"

title:
  family: HiraginoSans-W6
  size: 4
  color: "#231916"

bullet:
  text: "● "

code:
  family: Menlo
  size: 2
  color: "#FFF8ED"
  bg: "#231916"

background:
  image: images/bullets.png

counter:
  color: "#6B605C"

layouts:
  default:
    - {name: title,   x: 9.5%, y: 12%, width: 84%, height: 8%}
    - {name: content, x: 11%,  y: 24%, width: 87%, height: 64%}
  cover:
    - {name: title,   x: 36%, y: 38%, width: 64%, height: 24%}
    - {name: speaker, x: 36%, y: 64%, width: 64%, height: 4%, size: 2}
    - {name: account, x: 36%, y: 70%, width: 64%, height: 4%, size: 2, family: HiraginoSans-W3, color: "#6B605C"}
  message:
    - {name: title, x: center, y: 34%, width: 100%, height: 24%, size: 6}
    - {name: note,  x: center, y: 60%, width: 100%, height: 4%,  size: 2, family: HiraginoSans-W3, color: "#6B605C"}
```

- Write `family` as a PostScript name (`HiraginoSans-W6`). To change the weight of one slot, change its `family`
- `title.family` and `title.color` are not inherited from `font`, so set both
- `default` applies to pages without a layout, and `cover` applies to the first page automatically. Make the most used page (a bullet list, for example) the `default` and set its background as `background.image`, so those pages need no extra markup
- Code breaks when the body font is proportional, so give `code` a monospaced font
- Write positions and sizes as percentages. They scale with the background image when the pane size changes
- Quote colors as `"#RRGGBB"`. Unquoted, YAML reads them as comments

## The shape of the deck

```markdown
# Talk title {counter=hide}
<bg image="images/title.png"/>

Speaker name

<slot/>

@your_account / Affiliation

# Bullet list

- First point
  - Detail

# Section title {layout=section}
<bg image="images/section.png"/>

What this section covers, in one line
```

- Put `<bg .../>` on the line right below the heading, and leave one blank line before the body. See "Vertical position" for the reason
- The heading goes into the slot named `title`, and the rest goes into the other slots in declaration order. `<slot/>` moves on to the next slot
- Several attributes can be written as `{layout=thanks, counter=hide}`
- Use `<br>` for a line break inside a heading

## Text size

A size is an integer from 1 to 7, counted in rows. Text of size s is drawn in a box s rows tall.

On a pane of R rows and C columns, the measurements are:

- The height of the glyphs is about 77 / R * s percent of the pane height
- The width of one full-width (CJK) character is about 157 / C * s percent of the pane width

These were measured with Echoes' default font and shift a little with another font. On 50 rows and 160 columns, for example, one step is about 1.5% of the height and about 1.0% of the width per full-width character.

To choose a size:

1. On the original slide, measure the glyph height and the width per character of each element, as percentages
2. Divide by the formulas above to get the size as a decimal
3. Take the nearest integer. Take the smaller one when the text would not fit in the width

With few rows, one step is coarse and more elements fit no integer. On 42 rows the body text could only be 0.8 or 1.2 times the original. Around 50 rows, the common Keynote sizes (22, 28, 36, 48 and 60 points) land close to integers. When sizes do not fit, suggest changing the row count of the pane (the font size in Echoes) before touching the theme.

## Horizontal position

- In a left-aligned slot, text starts "slot width / 16 (rounded down)" cells inside the slot's left edge. Headings and paragraphs start one more cell to the right; list items do not
- So the column of the text's left edge is `round(x% * C) + floor(slot width in cells / 16)`. Work back from the wanted position to get `x`
- Text can only sit on cell boundaries. One cell is 100 / C percent of the width, and theme.yml cannot fix an offset smaller than that
- To line text up with a rule or a card in the background image, place the text first, then redraw the background image so that it meets the text's left edge
- With a font set, a slot with `x: center` is centered on the pane by Echoes, which measures the glyph widths. Text cannot be centered on anything but the pane

## Vertical position

- `y: N%` becomes row `round(N% * R)`. Text of size s takes s rows from there, and the center of the glyphs sits slightly above the center of the box
- Each blank line moves what follows down by as many rows as the body size. With a body size of 3, one blank line is 3 rows
- Blank lines at the start of a slot count too. This is why `<bg .../>` goes right below the heading and the body is preceded by exactly one blank line. Set `y` to "the wanted row minus the body size"
- The heading goes only into the `title` slot, so blank lines do not affect it
- `y: center` measures the content and centers it vertically on the pane. It holds up when the number of lines changes, but the position is fixed at 50%

## Wrapping and running out of columns

- Wrapping counts cells. One full-width character is "2 cells * size". The glyphs are narrower than that, so text wraps even when it looks like there is room
- To keep text on one line, the slot width in cells must be at least "characters * 2 * size". If it is not, widen the slot's `width`. A slot may be wider than the area it appears to cover
- For left-aligned text, "start column + characters * 2 * size - 1" must not exceed the pane's columns. When it does, Echoes moves the whole run to the left edge of the next line and the page falls apart
- The column count shifts by one or two with the window width. Do not place text at the limit; leave at least one column to spare. When there is no room to spare, lower the size or move the text to the left

## Aspect ratio

- A background image is stretched over the whole pane. It is distorted unless the pane is 16:9
- Keynote keeps 16:9 and adds black bars, so comparing full screen against full screen on a 16:10 display shows only przn stretched vertically
- Full screen on a 16:9 display (a projector or an external display) matches. Find out which screen the talk uses and match that one

## What przn cannot do

theme.yml cannot do the following. Rather than stacking workarounds, say so and consider a change to przn.

- A different marker or text size for nested list items only (every depth is drawn with `bullet.text` at the body size)
- Fractional sizes
- An image as the list marker (use a symbol or an emoji instead)
- Fine control of the spacing between list items (a blank line between items adds one body size)
- Keeping the aspect ratio of the background image
