# frozen_string_literal: true

require 'test_helper'
require 'tempfile'
require 'tmpdir'

class FileWatcherTest < Test::Unit::TestCase
  POLL = 0.05

  test 'fires the change handler when an existing file is touched' do
    Tempfile.create(['watched', '.md']) do |tmp|
      tmp.write("v1\n")
      tmp.flush

      seen = Queue.new
      w = Przn::FileWatcher.new([tmp.path], interval: POLL)
      w.start { |path| seen << path }
      sleep POLL * 2

      File.write(tmp.path, "v2\n")
      # Make sure the mtime moves — some filesystems have second-resolution.
      File.utime(Time.now, Time.now + 1, tmp.path)

      changed = Timeout.timeout(2) { seen.pop }
      assert_equal tmp.path, changed
    ensure
      w&.stop
    end
  end

  test 'fires when a previously-missing file is created' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'theme.yml')
      refute File.exist?(path), 'sanity: path should not exist yet'

      seen = Queue.new
      w = Przn::FileWatcher.new([path], interval: POLL)
      w.start { |p| seen << p }
      sleep POLL * 2

      File.write(path, "font:\n  family: Menlo\n")
      changed = Timeout.timeout(2) { seen.pop }
      assert_equal path, changed
    ensure
      w&.stop
    end
  end

  test 'does not fire when the file is not modified' do
    Tempfile.create(['watched', '.md']) do |tmp|
      tmp.write("v1\n")
      tmp.flush

      seen = Queue.new
      w = Przn::FileWatcher.new([tmp.path], interval: POLL)
      w.start { |path| seen << path }
      sleep POLL * 4

      assert seen.empty?, 'no change → no callback fires'
    ensure
      w&.stop
    end
  end

  test 'an exception in the handler does not stop the watcher' do
    Tempfile.create(['watched', '.md']) do |tmp|
      tmp.write("v1\n")
      tmp.flush

      fires = Queue.new
      w = Przn::FileWatcher.new([tmp.path], interval: POLL)
      first = true
      w.start do |path|
        fires << path
        if first
          first = false
          raise 'boom from handler'
        end
      end
      sleep POLL * 2

      # First save raises inside the handler …
      File.utime(Time.now, Time.now + 1, tmp.path)
      Timeout.timeout(2) { fires.pop }

      # … the second save still gets through.
      File.utime(Time.now, Time.now + 2, tmp.path)
      Timeout.timeout(2) { fires.pop }
    ensure
      w&.stop
    end
  end
end
