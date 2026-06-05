# przn

A terminal presentation tool written in Ruby

# Slide format

Every <color=cyan>`# h1`</color> starts a new slide.

Below the heading you can write **bold**, *italic*, `inline code`, ~~strikethrough~~, and the usual markdown.

# Lists

Unordered, ordered, and nested:

- pick a fruit
- or a vegetable
  - leafy ones too
- something else

1. first
2. second
3. third

# Code blocks

```ruby
class Slide
  attr_reader :title, :body
end
```

```python
def fib(n):
    return n if n < 2 else fib(n-1) + fib(n-2)
```

# Block quotes

> Code is read more often than it is written.

> Tables, lists, and the rest of standard markdown render normally.

# Tables

| Language | Year | Designer |
|----------|------|----------|
| Ruby     | 1995 | Matz |
| Python   | 1991 | Guido |
| Lisp     | 1958 | McCarthy |

# Definition lists

term
: definition for the term

another term
: another definition

# Text sizing — `<size=N>`

<size=xx-small>xx-small</size> <size=x-small>x-small</size> <size=small>small</size> <size=large>large</size>

<size=x-large>x-large</size> text

<size=xx-large>xx-large</size> text

<size=xxx-large>xxx-large</size> text

<size=xxxx-large>biggest</size> text

# Color — `<color=NAME>`

<color=red>red</color>, <color=green>green</color>, <color=yellow>yellow</color>, <color=blue>blue</color>, <color=magenta>magenta</color>, <color=cyan>cyan</color>

Plus 6-digit hex: <color=ff5555>tomato-ish</color>, <color=50fa7b>mint</color>, <color=8be9fd>sky</color>

# Font — `<font>`

<font face="Helvetica Neue" size="x-large">Helvetica Neue</font>

<font face="Menlo" color="green" size="large">monospace in green</font>

<font face="Georgia" size="xx-large" color="cyan">all three</font> at once

# Alignment — `<center>` / `<right>`

<center>centered line</center>

<right>right-aligned line</right>

The bare paragraph stays left-aligned for contrast.

# Slide background — `<bg>`

<bg color="#1a1a2e"/>

A `<bg>` directive applies for this slide only. The next slide reverts.

# Background — gradient

<bg from="#1a1a2e" to="#16213e" angle="90"/>

`<bg from="..." to="..." angle="..."/>` ships a linear gradient (Echoes' OSC 7772).

# Background — image

<bg image="ruby.png"/>

`<bg image="ruby.png"/>` uses the Kitty Graphics Protocol at `z: -1` so text layers on top.

# Image — flow (intrinsic size)

<img src="ruby.png"/>

# Image — relative_height="70"

<img src="ruby.png" relative_height="70"/>

# Image — width="N%"

<img src="ruby.png" width="40%"/>

# Image — absolute position

<img src="ruby.png" x="5c"  y="3c"  relative_height="40"/>
<img src="ruby.png" x="50%" y="50%" relative_height="40"/>

# Absolute-position text — `<at>`

<at x="5"  y="5">top-left ish</at>
<at x="40" y="15"><size=x-large>BIG</size></at>
<at x="60" y="20"><color=red>warn</color></at>
<at x="50%" y="50%"><font face="Georgia" size="xx-large" color="cyan">dead center</font></at>

# Shapes and Lines

<rect x="10" y="5"  width="20" height="6" rx="1" fill="tomato"/>
<circle cx="60%" cy="40%" r="6" fill="gold"/>
<ellipse cx="85%" cy="40%" rx="8" ry="4" fill="cyan"/>
<line x1="10" y1="20" x2="70" y2="20" stroke="white" stroke-width="0.3"/>
<arrow x1="10" y1="24" x2="70" y2="24" stroke="cyan" stroke-width="0.4"/>
<polyline points="10,26 25,28 40,26 55,28 70,26" stroke="lime" stroke-width="0.4" fill="none"/>
<polygon points="50%,3 60%,15 50%,20 40%,15" fill="orange"/>
<path d="M 30 27 C 45 23 55 31 70 27" stroke="white" stroke-width="0.4" fill="none"/>

# Two columns {layout=two-column}

left side

- bullet A
- bullet B

<slot/>

right side

- bullet C
- bullet D

# Takahashi method {layout=takahashi}

たかはし

# Title only {layout=title-only}

# Comments

<!-- this comment is hidden; the slide renders only the prose below -->

Comments use `<!-- ... -->` (single-line or multi-line) and never appear on the rendered slide.

# Speaker notes

The next sentence has a hidden side-strip note. <note>this never appears on the audience screen</note> Everything around the note still shows.

The note is visible in `--present` mode on the presenter pane.

# Step builds — `<wait/>`

A `<wait/>` on its own line splits the slide into steps.

<wait/>

Press Space again — the next group reveals.

<wait/>

And again — the layout doesn't reflow, the hidden text was already reserved.

# Thank you

That's all — enjoy.
