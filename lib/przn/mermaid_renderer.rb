# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require 'fileutils'
require 'shellwords'

module Przn
  # Shell-out wrapper around the Mermaid CLI (`mmdc`). Given a Mermaid
  # source string, returns the path to a rendered PNG — cached for the
  # life of the session in a tmpdir keyed by SHA256 of the source so
  # the same diagram on multiple slides (or after `r` reload) shells
  # out exactly once.
  #
  # The PNG is rendered with `-b transparent` so the slide background
  # (theme `bg`, gradient, image) shows through. Width is fixed at
  # 1600 px so the rendered image is high-res enough for any cell
  # placement; the Kitty Graphics protocol scales to whatever cell
  # rect the placement carves out.
  #
  # When `mmdc` is missing or the render fails for any reason, returns
  # nil and the caller falls back to rendering the source as a plain
  # fenced block.
  module MermaidRenderer
    CANVAS_WIDTH_PX = 1600

    @cache = {}
    @cache_mutex = Mutex.new
    @tmpdir = nil
    @tmpdir_mutex = Mutex.new

    module_function

    # Returns the path to a rendered PNG, or nil if rendering failed.
    # `theme` defaults to mermaid's `default`; future hook for a theme
    # knob (theme.yml `mermaid.theme`).
    def render(source, theme: 'default')
      return nil if source.nil? || source.strip.empty?
      key = Digest::SHA256.hexdigest("#{theme}:#{source}")
      cached = @cache_mutex.synchronize { @cache[key] }
      return cached if cached

      dir = ensure_tmpdir
      in_path  = File.join(dir, "#{key}.mmd")
      out_path = File.join(dir, "#{key}.png")
      File.write(in_path, source)

      cmd = ['mmdc',
             '--quiet',
             '-i', in_path,
             '-o', out_path,
             '-t', theme,
             '-b', 'transparent',
             '-w', CANVAS_WIDTH_PX.to_s]
      ok = system(*cmd, out: File::NULL, err: File::NULL)

      return nil unless ok && File.exist?(out_path) && File.size(out_path).positive?

      @cache_mutex.synchronize { @cache[key] = out_path }
      out_path
    rescue StandardError
      nil
    end

    # Bare check for whether the CLI is reachable. Used by the
    # renderer to decide whether to even try (or to short-circuit to
    # the plain-fence fallback).
    def available?
      return @available unless @available.nil?
      @available = system('mmdc', '--version', out: File::NULL, err: File::NULL)
    end

    def reset!
      @cache_mutex.synchronize { @cache.clear }
      @tmpdir_mutex.synchronize do
        FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
        @tmpdir = nil
      end
      @available = nil
    end

    def ensure_tmpdir
      @tmpdir_mutex.synchronize do
        @tmpdir ||= Dir.mktmpdir('przn-mermaid-')
      end
    end
  end
end
