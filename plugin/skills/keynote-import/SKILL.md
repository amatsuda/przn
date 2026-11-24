---
name: keynote-import
description: Convert a Keynote .key file into a przn theme. Builds theme.yml and background images, renders the deck in Echoes, and matches it to the original Keynote slides by comparing measurements. Keynote theme files (.kth) are not supported yet. Use this when matching the look of przn slides to a Keynote file, for example "turn this .key into a przn theme" or "przn looks different from the Keynote version".
---

# keynote-import

Convert a Keynote `.key` file into a przn theme. Keynote theme files (`.kth`) are not supported yet.

The result is three things, placed in the same directory.

- `theme.yml`
    - Fonts, colors, and one layout per kind of page
- `images/`
    - One background image per kind of page (1920x1080 PNG)
- The deck
    - If a deck already exists, use it and adjust its markup to the theme. Otherwise create `slides.md` as a sample that shows how to write each kind of page

The work is a loop: extract, build, render and measure, adjust. Matching by eye takes many rounds, so compare numbers from the start.

## Requirements

- macOS
    - Reading a Keynote file does not need Keynote itself, but the fonts and the color handling assume macOS
- [Echoes](https://github.com/amatsuda/echoes)
    - The theme this skill produces is meant to be shown in Echoes. Font selection, centering by measured glyph width, drawing text over a background image, and saving the pane as an image all rely on Echoes. Other terminals will not reproduce the look
    - Checking the render (`scripts/echoes_capture.sh`) launches Echoes. Point `ECHOES_ROOT` at an Echoes checkout, or install Echoes.app with `echoes install`, or install the echoes gem
- ImageMagick (`magick`)
    - Used to compose the background images and to measure images
- Ruby and przn
    - The bundled scripts are written in Ruby

## Steps

### 1. Find out first

- Which pages are needed. Not every page of the Keynote file has to be converted
- The size of the pane used for the talk (columns and rows). It decides the text size, so do not tune anything before knowing it. If przn is running, find its terminal with `ps` and read the size with `stty -f /dev/ttysNNN size`
- The aspect ratio of the screen used for the talk. A background image is stretched over the whole pane

### 2. Extract from Keynote

```
ruby scripts/keynote_extract.rb template.key <work directory>
```

For every slide this lists the shapes, images and text boxes with their position and size (in points; a slide is usually 960x540), corner radius, colors, fonts and font sizes. Images land in `<work directory>/Data/`.

- `Data/st-*.jpg` are thumbnails of the slides. Use them to tell which page is which. They are saved in Display P3, so convert them to sRGB before reading colors from them
- For a text box whose height is 0, the y position is the top of the text
- Leave the original `.key` untouched. Extract into a work directory

### 3. Build the background images

Treat przn as drawing text only. Bake patterns, cards, rules and logos into one background image per kind of page. Double the points to get 1920x1080 pixels and compose with ImageMagick.

```
magick pattern.png \
  \( logo.png -resize 590x356! \) -geometry +79+338 -composite \
  -fill white -stroke '#231916' -strokewidth 8 -draw 'roundrectangle 713,130 1843,950 66,66' \
  -strip PNG24:work/title.png
```

Convert colors last. Echoes sends image pixels to the screen without color conversion, so on a wide-gamut display (a MacBook, for example) images look more vivid than in Keynote. Echoes does convert text colors, so only images are off. Compose in sRGB values, then replace them with Display P3 values, strip the profile, and put the result in `images/`.

```
magick work/title.png \
  -profile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" \
  -profile "/System/Library/ColorSync/Profiles/Display P3.icc" \
  -strip PNG24:images/title.png
```

Skip this conversion when the talk is given on an sRGB display. Decide which screen to match and ship one set of images.

### 4. Write theme.yml and the deck

`references/layout.md` explains the format and how to choose positions and sizes. Read it before deciding any coordinate. przn places things by several rules that are not obvious, and without them every position turns into trial and error.

### 5. Render and measure

```
scripts/echoes_capture.sh slides.md <output directory> [font size]
```

This opens a temporary Echoes window and saves every page as `slide-N.png`. `size.txt` holds the columns and rows. The user's Echoes configuration is not changed.

- The window is as large as the user's last Echoes window. Pass a font size to change the columns and rows
- The saved images are in the display's color space. Convert them to sRGB before measuring

```
magick slide-1.png -profile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" s1.png
ruby scripts/measure_text.rb s1.png 0.375 0.955 0.14 0.86
ruby scripts/measure_text.rb original-slide1.png 0.375 0.955 0.14 0.86
```

`measure_text.rb` prints, for each band of text, its top, bottom, height, center, left edge and width as percentages. Run it on the original slide and on the przn render, then adjust theme.yml by the difference. Use the region arguments to keep logos and other non-text parts out.

Use these captures for position and size. Image colors in a capture differ from what the screen shows, so they cannot confirm colors.

### 6. Colors

Whether colors match can only be confirmed on the real screen. These steps do not confirm it, so report colors as unverified.

If the user provides screenshots of Keynote and przn, compare pixel values at the same spots. Both are in the same display color space, so the values can be compared as they are. The size of a screenshot and the area the slide covers also tell the pane's aspect ratio and row count. Check first that it was not taken at a row count the theme was not tuned for.

## Reporting

- Show the result as the original's numbers next to przn's
- For differences that could not be closed, give the reason and the size. The usual reasons are that sizes come in integer steps and that text can only be placed on cell boundaries
- Do not report something as matching without measuring it. Say what was measured: values in the files, an Echoes capture, or a screenshot of the real screen

## Bundled files

- `scripts/keynote_extract.rb`
    - Unpacks a Keynote file and lists its contents
- `scripts/echoes_capture.sh`
    - Opens Echoes temporarily and saves every page as an image. Calls `capture_slides.rb`
- `scripts/measure_text.rb`
    - Measures the position and size of text in an image
- `references/layout.md`
    - The theme.yml format, przn's placement rules, and how to choose sizes
