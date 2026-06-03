# frozen_string_literal: true

module Przn
  module ImageUtil
    module_function

    def image_size(path)
      return nil unless File.exist?(path)

      File.open(path, 'rb') do |f|
        header = f.read(8)
        return nil unless header && header.size >= 4

        # PNG
        if header.b == "\x89PNG\r\n\x1a\n".b
          f.seek(16)
          w = f.read(4)&.unpack1('N')
          h = f.read(4)&.unpack1('N')
          return [w, h] if w && h
        end

        # JPEG
        f.seek(0)
        if header.b[0..1] == "\xFF\xD8".b
          f.seek(2)
          loop do
            marker = f.read(2)
            break unless marker && marker.size == 2 && marker.getbyte(0) == 0xFF
            type = marker.getbyte(1)
            if [0xC0, 0xC1, 0xC2].include?(type)
              f.read(3)
              h = f.read(2)&.unpack1('n')
              w = f.read(2)&.unpack1('n')
              return [w, h] if w && h
            end
            len = f.read(2)&.unpack1('n')
            break unless len && len >= 2
            f.seek(len - 2, IO::SEEK_CUR)
          end
        end

        # GIF
        f.seek(0)
        sig = f.read(6)
        if sig&.start_with?('GIF8')
          w = f.read(2)&.unpack1('v')
          h = f.read(2)&.unpack1('v')
          return [w, h] if w && h
        end
      end
      nil
    rescue StandardError
      nil
    end

    # Display image using kitten icat with --place for positioning
    def kitty_icat(path, cols:, rows:, x:, y:)
      args = ['kitten', 'icat', '--transfer-mode', 'stream',
              '--place', "#{cols}x#{rows}@#{x}x#{y}",
              File.expand_path(path)]
      IO.popen(args, 'r', err: File::NULL) { |io| io.read }
    end

    def kitty_terminal?
      ENV['TERM'] == 'xterm-kitty' ||
        ENV['TERM_PROGRAM'] == 'kitty' ||
        ENV['TERM_PROGRAM'] == 'Echoes'
    end

    PNG_MAGIC = "\x89PNG\r\n\x1a\n".b.freeze

    def png?(path)
      File.open(path, 'rb') { |f| f.read(8)&.b == PNG_MAGIC }
    rescue Errno::ENOENT
      false
    end

    # Kitty Graphics Protocol: upload a PNG file by path with the given id.
    # Kitty reads the file directly from disk; we just send a small APC
    # control sequence with the base64-encoded path. Use this once per
    # image; subsequent renders only need a placement command.
    # https://sw.kovidgoyal.net/kitty/graphics-protocol/
    def kitty_upload_png(path, image_id:)
      encoded = [File.expand_path(path)].pack('m0')
      "\e_Ga=t,t=f,f=100,i=#{image_id},q=2;#{encoded}\e\\"
    end

    # Kitty Graphics Protocol: upload arbitrary image bytes inline via
    # the direct-data transmission mode (`t=d`). Used by the shape-
    # drawing tags (`<rect>`, `<circle>`, `<line>`, …) which build a
    # tiny self-contained SVG document per shape and ship it here.
    # Echoes content-sniffs the payload and routes SVGs through its
    # native CoreGraphics rasterizer (sub-millisecond for path-only
    # SVGs — the case shape primitives always hit). `f=100` is the
    # default PNG format code; the sniffer overrides it for SVG.
    def kitty_upload_inline(bytes, image_id:)
      encoded = [bytes.to_s].pack('m0')
      "\e_Ga=t,t=d,f=100,i=#{image_id},q=2;#{encoded}\e\\"
    end

    # Kitty Graphics Protocol: place a previously-uploaded image at the
    # current cursor position, scaled to fit `cols` x `rows` cells.
    # `z` sets the z-index — negative values draw the image behind
    # text cells (used by slide background images at z: -1).
    def kitty_place(image_id:, cols:, rows:, z: nil)
      params = +"a=p,i=#{image_id},c=#{cols},r=#{rows},q=2"
      params << ",z=#{z}" if z
      "\e_G#{params}\e\\"
    end

    # Kitty Graphics Protocol: delete every placement for a specific
    # image id while keeping the stored image data alive (lowercase
    # `d=i`). Used to wipe the previous slide's background image
    # before placing a new one, without forcing a re-upload.
    def kitty_delete_placements(image_id:)
      "\e_Ga=d,d=i,i=#{image_id},q=2\e\\"
    end

    # Kitty Graphics Protocol: delete every placement and free the
    # stored image data. Used on quit so previously-rendered images
    # don't leak through onto the user's restored shell screen
    # (placements aren't tied to the alt-screen buffer in most
    # kitty-protocol implementations, so leaving the alt screen
    # alone isn't enough to hide them). `q=2` suppresses the OK reply.
    def kitty_clear_all
      "\e_Ga=d,d=A,q=2\e\\"
    end

    # Sixel via img2sixel
    def sixel_available?
      @sixel_available = system('command -v img2sixel > /dev/null 2>&1') if @sixel_available.nil?
      @sixel_available
    end

    def sixel_encode(path, width: nil, height: nil)
      return nil unless sixel_available?
      return nil unless File.exist?(path)

      args = ['img2sixel']
      args += ['-w', width.to_s] if width
      args += ['-h', height.to_s] if height
      args << path
      IO.popen(args, 'r', err: File::NULL) { |io| io.read }
    end
  end
end
