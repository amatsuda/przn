# frozen_string_literal: true

module Przn
  # Polling-based watcher over a small fixed set of files. Single
  # background thread checks `File.mtime` every `interval` seconds; the
  # first time a path's mtime moves past the snapshot taken at start,
  # the block runs with that path as its argument.
  #
  # Built around the on-save edit cadence: a human typing in their
  # editor produces at most one save per few seconds, so a 0.5 s poll
  # is well below human-perception latency and saves us a gem dep on
  # rb-fsevent / listen.
  #
  # Paths that don't exist when `start` is called (e.g. an optional
  # `theme.yml` that hasn't been written yet) are watched too — the
  # mtime starts at nil, so the first save trips the change handler.
  class FileWatcher
    DEFAULT_INTERVAL = 0.5

    def initialize(paths, interval: DEFAULT_INTERVAL)
      @paths    = paths.compact
      @interval = interval
      @thread   = nil
      @stop     = false
    end

    def start(&on_change)
      return if @thread
      mtimes = snapshot
      @stop = false
      @thread = Thread.new do
        Thread.current.abort_on_exception = false
        until @stop
          sleep @interval
          break if @stop
          @paths.each do |path|
            current = mtime_for(path)
            next if current == mtimes[path]
            mtimes[path] = current
            begin
              on_change.call(path)
            rescue StandardError
              # Don't kill the watcher because a single notification
              # raised — the next save still gets a chance.
            end
          end
        end
      end
    end

    def stop
      @stop = true
      @thread&.join
      @thread = nil
    end

    private

    def snapshot
      @paths.each_with_object({}) { |p, h| h[p] = mtime_for(p) }
    end

    def mtime_for(path)
      File.mtime(path)
    rescue Errno::ENOENT
      nil
    end
  end
end
