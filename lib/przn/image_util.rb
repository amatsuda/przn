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
    rescue
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
      ENV['TERM'] == 'xterm-kitty' || ENV['TERM_PROGRAM'] == 'kitty'
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

    # Kitty Graphics Protocol: place a previously-uploaded image at the
    # current cursor position, scaled to fit `cols` x `rows` cells.
    def kitty_place(image_id:, cols:, rows:)
      "\e_Ga=p,i=#{image_id},c=#{cols},r=#{rows},q=2\e\\"
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
