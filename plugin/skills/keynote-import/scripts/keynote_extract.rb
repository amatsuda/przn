#!/usr/bin/env ruby
# frozen_string_literal: true

# Unpack a Keynote file and print what each slide is made of.
#
# usage: ruby keynote_extract.rb TEMPLATE.key OUTDIR
#
# OUTDIR receives the unzipped package (images are under OUTDIR/Data).
# For every slide this prints, in drawing order, each shape / image / text
# box with its position and size in points (the slide is usually 960x540),
# corner radius, fill and stroke colors, and the font, size and color of
# each text run.
module KeynoteExtract
  # Keynote's .iwa files are Snappy blocks, each behind a 4-byte header
  # holding the block length.
  module Snappy
    module_function

    def decode_iwa(raw)
      pos = 0
      out = String.new(encoding: Encoding::BINARY)
      while pos < raw.bytesize
        length = little_endian(raw, pos + 1, 3)
        pos += 4
        out << decompress(raw.byteslice(pos, length))
        pos += length
      end
      out
    end

    def decompress(data)
      pos = 0
      # Skip the uncompressed-length varint
      pos += 1 while data.getbyte(pos) & 0x80 != 0
      pos += 1
      out = String.new(encoding: Encoding::BINARY)
      while pos < data.bytesize
        tag = data.getbyte(pos)
        pos += 1
        kind = tag & 3
        if kind == 0
          length = tag >> 2
          if length >= 60
            extra = length - 59
            length = little_endian(data, pos, extra)
            pos += extra
          end
          length += 1
          out << data.byteslice(pos, length)
          pos += length
          next
        end
        if kind == 1
          length = ((tag >> 2) & 7) + 4
          offset = ((tag >> 5) << 8) | data.getbyte(pos)
          pos += 1
        else
          width = kind == 2 ? 2 : 4
          length = (tag >> 2) + 1
          offset = little_endian(data, pos, width)
          pos += width
        end
        # Copy byte by byte: the source range may overlap what is being written
        length.times { out << out.getbyte(out.bytesize - offset) }
      end
      out
    end

    def little_endian(data, pos, width)
      data.byteslice(pos, width).bytes.each_with_index.sum { |byte, index| byte << (8 * index) }
    end
  end

  # Keynote publishes no schema for its protobuf messages, so they are
  # decoded structurally: field numbers and wire types only.
  module Protobuf
    module_function

    def varint(data, pos)
      result = 0
      shift = 0
      loop do
        byte = data.getbyte(pos)
        pos += 1
        result |= (byte & 0x7f) << shift
        return [result, pos] if byte & 0x80 == 0

        shift += 7
      end
    end

    # Returns [[field number, wire type, value], ...], or nil when the bytes
    # are not a message (a string or raw data that only looked like one).
    def parse(data)
      pos = 0
      fields = []
      while pos < data.bytesize
        key, pos = varint(data, pos)
        number = key >> 3
        wire = key & 7
        return nil if number == 0

        case wire
        when 0
          value, pos = varint(data, pos)
        when 1
          return nil if pos + 8 > data.bytesize

          value = data.byteslice(pos, 8).unpack1('E')
          pos += 8
        when 5
          return nil if pos + 4 > data.bytesize

          value = data.byteslice(pos, 4).unpack1('e').round(4)
          pos += 4
        when 2
          length, pos = varint(data, pos)
          return nil if pos + length > data.bytesize

          value = data.byteslice(pos, length)
          pos += length
        else
          return nil
        end
        fields << [number, wire, value]
      end
      fields
    rescue NoMethodError
      # A varint ran past the end of the data
      nil
    end

    def get(fields, number)
      fields.select { |n, _, _| n == number }.map { |_, _, value| value }
    end

    # Flatten a message into text so colors and font names can be searched.
    def text_dump(data)
      fields = parse(data)
      string = data.dup.force_encoding(Encoding::UTF_8)
      if fields.nil? || fields.empty?
        return string.valid_encoding? ? string.inspect : ''
      end
      return string.inspect if string.valid_encoding? && string.match?(%r{\A[\p{Alnum} \-_.:/*@()]{2,}\z})

      parts = fields.map { |number, wire, value| "#{number}: #{wire == 2 ? text_dump(value) : value}" }
      "{#{parts.join(', ')}}"
    end

    # An .iwa stream is a sequence of archives: a header listing the
    # messages that follow, then their payloads.
    def objects(data)
      pos = 0
      out = []
      while pos < data.bytesize
        length, pos = varint(data, pos)
        info = parse(data.byteslice(pos, length))
        pos += length
        identifier = get(info, 1).first
        get(info, 2).each do |message|
          meta = parse(message)
          size = get(meta, 3).first
          out << [identifier, get(meta, 1).first, data.byteslice(pos, size)]
          pos += size
        end
      end
      out
    end
  end

  class Report
    include Protobuf

    SHAPE = 2011
    IMAGE = 3005
    TEXT_STORAGE = 2001

    def initialize(key_path, out_dir)
      @key_path = key_path
      @out_dir = out_dir
    end

    def print
      # ditto, not unzip: unzip stops at a prompt on a file name stored
      # without the zip UTF-8 flag, as Keynote does for non-ASCII image names.
      system('ditto', '-x', '-k', @key_path, @out_dir, exception: true)
      index = File.join(@out_dir, 'Index')
      decoded = Dir.children(index).grep(/\.iwa\z/).sort.to_h do |name|
        [name, Snappy.decode_iwa(File.binread(File.join(index, name)))]
      end
      @styles = objects(decoded['DocumentStylesheet.iwa']).to_h { |identifier, _, payload| [identifier, payload] }

      decoded.each do |name, data|
        print_slide(name, data) if name.start_with?('Slide')
      end

      data_dir = File.join(@out_dir, 'Data')
      puts "== images in #{data_dir}"
      Dir.children(data_dir).sort.each { |name| puts "  #{name}" }
    end

    private

    def print_slide(name, data)
      items = objects(data)
      storages = items.select { |_, kind, _| kind == TEXT_STORAGE }.to_h { |identifier, _, payload| [identifier, parse(payload)] }
      puts "== #{name}"
      items.each do |_, kind, payload|
        print_drawable(kind, parse(payload), storages) if [SHAPE, IMAGE].include?(kind)
      end
    end

    def print_drawable(kind, top, storages)
      base = parse(get(top, 1).first)
      drawable = kind == SHAPE ? parse(get(base, 1).first) : base
      geometry = parse(get(drawable, 1).first)
      position = parse(get(geometry, 1).first).map { |_, _, v| v.round(1) }
      size = parse(get(geometry, 2).first).map { |_, _, v| v.round(1) }
      label = get(drawable, 8).first&.dup&.force_encoding(Encoding::UTF_8) || '?'
      line = format('  %-22s pos=%-16s size=%-16s', label, position.inspect, size.inspect)
      if kind == IMAGE
        puts "#{line} image"
        return
      end

      path = get(base, 3).first
      scalar = path && get(parse(path), 4).first
      line += " radius=#{get(parse(scalar), 2).first}" if scalar
      style = @styles[get(parse(get(base, 2).first), 1).first]
      line += " shape-colors=#{colors(text_dump(style)).inspect}" if style
      puts line

      storage_ref = get(top, 2).first
      storage = storage_ref && storages[get(parse(storage_ref), 1).first]
      print_text(storage) if storage && get(storage, 3).first
    end

    def print_text(storage)
      puts "      text=#{get(storage, 3).first.dup.force_encoding(Encoding::UTF_8).inspect}"
      get(storage, 5).each do |table|
        get(parse(table), 1).each do |entry|
          entry_fields = parse(entry)
          style_ref = get(entry_fields, 2).first
          paragraph_style = style_ref && @styles[get(parse(style_ref), 1).first]
          next unless paragraph_style

          dump = text_dump(paragraph_style)
          font = dump[/"([A-Za-z][-A-Za-z0-9]+)"/, 1]
          # Font sizes are the only floats above a few points in a paragraph style
          font_size = dump.scan(/(?:\A|[{ ])(?:3|9): ([0-9]+\.[0-9]+)(?=[,}])/).flatten.find { |v| v.to_f >= 4 }
          puts "      from char #{get(entry_fields, 1).first}: font=#{font} size=#{font_size} color=#{colors(dump).first}"
        end
      end
    end

    def colors(dump)
      dump.scan(/3: ([0-9.]+), 4: ([0-9.]+), 5: ([0-9.]+), 6: 1\.0/).map do |rgb|
        format('#%02X%02X%02X', *rgb.map { |c| (c.to_f * 255).round })
      end
    end
  end
end

KeynoteExtract::Report.new(*ARGV).print
