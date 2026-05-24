# przn

A terminal presentation tool written in Ruby

# Features

- **Markdown** based slides
- *Kitty text sizing* protocol support
- Simple keyboard navigation

# Code Blocks

```ruby
puts "Hello from przn!"
```

# Inline Formatting

This is **bold**, this is *italic*, and this is `inline code`.

> This is a blockquote

# Lists

- First item
- Second item
- Third item

1. Ordered one
2. Ordered two
3. Ordered three

# Custom Styling

{::tag name="xx-large"}BIG text{:/tag}

{::tag name="x-large"}large text{:/tag}

{::tag name="large"}large text{:/tag}

normal and {::tag name="red"}red text{:/tag} mixed

# Image (PNG)

![](doge.png){:relative_height="70"}

# Image (JPG)

![](doge.jpg){:relative_height="70"}

# Image (XML form)

<img src="doge.png" relative_height="70"/>

# Image (absolute position)

<img src="doge.png" x="5"   y="3"   relative_height="40"/>
<img src="doge.png" x="50%" y="50%" relative_height="40"/>

# Absolute-position text

<at x="10" y="10">top-left ish</at>
<at x="40" y="15"><size=3>BIG</size></at>
<at x="80" y="25"><color=red>warn</color></at>
<at x="50%" y="50%">dead center</at>

# Two columns {layout=two-column}

left side text
- bullet A
- bullet B

<slot/>

right side text
- bullet C
- bullet D

# Thank You!

That's all! Enjoy!
