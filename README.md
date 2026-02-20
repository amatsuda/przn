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

On [Kitty](https://sw.kovidgoyal.net/kitty/)-compatible terminals, sized text is rendered using the OSC 66 text sizing protocol. On other terminals, the markup is silently ignored.

### Alignment

```markdown
{:.center}
centered text

{:.right}
right-aligned text
```

### Comments

```markdown
{::comment}
This text is hidden from the presentation.
{:/comment}
```

### Notes

```markdown
Visible text {::note}(speaker note){:/note}
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
