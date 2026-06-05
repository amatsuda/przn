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
    test 'emits an APC sequence with action=p, the given id, grid size, and C=1' do
      out = Przn::ImageUtil.kitty_place(image_id: 7, cols: 30, rows: 12)
      assert_equal "\e_Ga=p,i=7,c=30,r=12,C=1,q=2\e\\", out
    end

    test 'appends z= for background placements (z: -1 draws behind text)' do
      out = Przn::ImageUtil.kitty_place(image_id: 7, cols: 80, rows: 30, z: -1)
      assert_equal "\e_Ga=p,i=7,c=80,r=30,C=1,q=2,z=-1\e\\", out
    end

    test 'C=1 is always present so placements never wrap or scroll the screen' do
      out = Przn::ImageUtil.kitty_place(image_id: 1, cols: 999, rows: 999)
      assert(out.include?(',C=1,'), "expected C=1 in oversize placement: #{out.inspect}")
    end

    test 'positive x_off / y_off emit X= / Y= for sub-cell pixel placement' do
      out = Przn::ImageUtil.kitty_place(image_id: 7, cols: 30, rows: 12, x_off: 3, y_off: 5)
      assert_equal "\e_Ga=p,i=7,c=30,r=12,C=1,q=2,X=3,Y=5\e\\", out
    end

    test 'zero x_off / y_off omit X= / Y= so cell-aligned placements stay compact' do
      out = Przn::ImageUtil.kitty_place(image_id: 7, cols: 30, rows: 12, x_off: 0, y_off: 0)
      assert_equal "\e_Ga=p,i=7,c=30,r=12,C=1,q=2\e\\", out,
                   'zero offsets should not appear in the APC at all'
    end
  end

  sub_test_case 'kitty_delete_placements' do
    test 'emits action=d with d=i (lowercase) so storage stays cached' do
      assert_equal "\e_Ga=d,d=i,i=42,q=2\e\\",
                   Przn::ImageUtil.kitty_delete_placements(image_id: 42)
    end
  end

  sub_test_case 'kitty_delete_all_placements' do
    test 'emits d=a (lowercase) so all placements clear but image data stays cached' do
      assert_equal "\e_Ga=d,d=a,q=2\e\\", Przn::ImageUtil.kitty_delete_all_placements
    end
  end

  sub_test_case 'kitty_clear_all' do
    test 'emits an APC sequence with action=d that frees both placements and storage' do
      assert_equal "\e_Ga=d,d=A,q=2\e\\", Przn::ImageUtil.kitty_clear_all
    end
  end

  sub_test_case 'kitty_upload_inline' do
    test 'emits a t=d APC with the base64-encoded payload' do
      out = Przn::ImageUtil.kitty_upload_inline('<svg/>', image_id: 5)
      assert(out.start_with?("\e_G"), "expected APC start: #{out.inspect}")
      assert(out.end_with?("\e\\"),   "expected APC terminator: #{out.inspect}")
      controls, payload = out[3..-3].split(';', 2)
      pairs = controls.split(',').map { |p| p.split('=', 2) }.to_h
      assert_equal 't',   pairs['a']
      assert_equal 'd',   pairs['t']
      assert_equal '100', pairs['f']
      assert_equal '5',   pairs['i']
      assert_equal '2',   pairs['q']
      assert_equal '<svg/>', decode64(payload)
    end

    test 'round-trips arbitrary bytes including a newline' do
      bytes = "<svg>\n  <line x1='0' y1='0' x2='1' y2='1'/>\n</svg>\n"
      out = Przn::ImageUtil.kitty_upload_inline(bytes, image_id: 1)
      _, payload = out[3..-3].split(';', 2)
      assert_equal bytes, decode64(payload)
    end
  end
end
