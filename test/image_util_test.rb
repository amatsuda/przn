# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class ImageUtilTest < Test::Unit::TestCase
  def make_tmpfile(contents, ext: '.bin')
    f = Tempfile.new(['image_util_test', ext])
    f.binmode
    f.write(contents)
    f.flush
    f
  end

  def decode64(str)
    str.unpack1('m')
  end

  sub_test_case 'png?' do
    test 'returns true for files starting with the PNG signature' do
      tmp = make_tmpfile("\x89PNG\r\n\x1a\n\x00\x00".b, ext: '.png')
      assert_true Przn::ImageUtil.png?(tmp.path)
    ensure
      tmp&.close!
    end

    test 'returns false for non-PNG signatures' do
      tmp = make_tmpfile("GIF89a\x00\x00".b, ext: '.gif')
      assert_false Przn::ImageUtil.png?(tmp.path)
    ensure
      tmp&.close!
    end

    test 'returns false for files shorter than the signature' do
      tmp = make_tmpfile("\x89PNG".b)
      assert_false Przn::ImageUtil.png?(tmp.path)
    ensure
      tmp&.close!
    end

    test 'returns false for missing files' do
      assert_false Przn::ImageUtil.png?('/nonexistent/path/that/does/not/exist.png')
    end
  end

  sub_test_case 'kitty_upload_png' do
    test 'emits an APC sequence with action=t, format=PNG, the given id, and the base64-encoded path' do
      out = Przn::ImageUtil.kitty_upload_png('/tmp/foo.png', image_id: 42)

      assert(out.start_with?("\e_G"), "expected APC start: #{out.inspect}")
      assert(out.end_with?("\e\\"),   "expected APC terminator: #{out.inspect}")

      controls, payload = out[3..-3].split(';', 2)
      pairs = controls.split(',').map { |p| p.split('=', 2) }.to_h
      assert_equal 't',   pairs['a']
      assert_equal 'f',   pairs['t']
      assert_equal '100', pairs['f']
      assert_equal '42',  pairs['i']
      assert_equal '2',   pairs['q']
      assert_equal '/tmp/foo.png', decode64(payload)
    end

    test 'uses an absolute path even when given a relative one' do
      out = Przn::ImageUtil.kitty_upload_png('foo.png', image_id: 1)
      _, payload = out[3..-3].split(';', 2)
      decoded = decode64(payload)
      assert_equal File.expand_path('foo.png'), decoded
    end
  end

  sub_test_case 'kitty_place' do
    test 'emits an APC sequence with action=p, the given id, and grid size' do
      out = Przn::ImageUtil.kitty_place(image_id: 7, cols: 30, rows: 12)
      assert_equal "\e_Ga=p,i=7,c=30,r=12,q=2\e\\", out
    end
  end
end
