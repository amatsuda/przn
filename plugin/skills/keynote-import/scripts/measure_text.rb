#!/usr/bin/env ruby
# frozen_string_literal: true

# Print where the text sits in a slide image, as percentages of the image.
#
# usage: ruby measure_text.rb IMAGE [X0 X1 Y0 Y1]
#
# X0..Y1 limit the search to a region, each as a fraction of the image
# (default 0 1 0 1). Use the region to keep decorations such as logos out.
# Each output line is one horizontal band of text: its top, bottom, height
# and centre, and its left edge, right edge and width. Run it on the
# original slide and on the przn render, then compare the numbers.
#
# Text is detected as dark pixels or mid-gray pixels, so it works on light
# backgrounds. Pass images already cropped to the slide area.
# Needs ImageMagick (`magick`).
require 'open3'

class TextMeasure
  Row = Struct.new(:dark, :gray, :min, :max)

  def initialize(image, x0 = 0.0, x1 = 1.0, y0 = 0.0, y1 = 1.0)
    dimensions, = Open3.capture2('magick', 'identify', '-format', '%w %h', image)
    @width, @height = dimensions.split.map(&:to_i)
    @pixels, = Open3.capture2('magick', image, '-alpha', 'off', '-depth', '8', 'rgb:-', binmode: true)
    @left = (x0.to_f * @width).to_i
    @right = (x1.to_f * @width).to_i
    @top = y0.to_f * @height
    @bottom = y1.to_f * @height
  end

  def print
    rows = Array.new(@height) { |y| scan_row(y) }
    # A row belongs to a text band when it holds more than stray pixels
    threshold = [2, @width / 300].max
    start = nil
    (0..@height).each do |y|
      on = y < @height && rows[y].dark + rows[y].gray >= threshold
      start = y if on && start.nil?
      next if on || start.nil?

      print_band(rows, start, y)
      start = nil
    end
  end

  private

  def scan_row(y)
    row = Row.new(0, 0, nil, nil)
    return row unless y >= @top && y <= @bottom

    offset = (y * @width + @left) * 3
    (@left...@right).each do |x|
      kind = kind_of(@pixels.getbyte(offset), @pixels.getbyte(offset + 1), @pixels.getbyte(offset + 2))
      offset += 3
      next unless kind

      row[kind] += 1
      row.min ||= x
      row.max = x
    end
    row
  end

  def kind_of(red, green, blue)
    return :dark if red < 75 && green < 65 && blue < 65
    return :gray if (red - green).abs < 25 && (green - blue).abs < 25 && red > 85 && red < 135

    nil
  end

  def print_band(rows, top, bottom)
    # Thin bands are rules and borders, not text
    return if bottom - top < @height * 0.012

    band = rows[top...bottom]
    min_x = band.filter_map(&:min).min
    max_x = band.filter_map(&:max).max + 1
    kind = band.sum(&:dark) >= band.sum(&:gray) ? 'dark' : 'gray'
    puts format(
      '%-4s y %5.1f-%5.1f%% h %4.1f%% c %5.1f%%  x %5.1f-%5.1f%% w %4.1f%%',
      kind,
      top * 100.0 / @height,
      bottom * 100.0 / @height,
      (bottom - top) * 100.0 / @height,
      (top + bottom) * 50.0 / @height,
      min_x * 100.0 / @width,
      max_x * 100.0 / @width,
      (max_x - min_x) * 100.0 / @width
    )
  end
end

TextMeasure.new(*ARGV).print
