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
        if sig&.start_with?("GIF8")
          w = f.read(2)&.unpack1('v')
          h = f.read(2)&.unpack1('v')
          return [w, h] if w && h
        end
      end
      nil
    rescue
      nil
    end

    # Kitty graphics protocol: transmit file and display at given cell size
    def kitty_display(path, cols: nil, rows: nil)
      encoded_path = [File.expand_path(path)].pack('m0')
      params = +"a=T,t=f"
      params << ",c=#{cols}" if cols
      params << ",r=#{rows}" if rows
      "\e_G#{params};#{encoded_path}\e\\"
    end

    def kitty_terminal?
      ENV['TERM'] == 'xterm-kitty' || ENV['TERM_PROGRAM'] == 'kitty'
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
