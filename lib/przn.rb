# frozen_string_literal: true

require 'tmpdir'
require 'securerandom'

require_relative 'przn/version'
require_relative 'przn/kitty_text'
require_relative 'przn/image_util'
require_relative 'przn/parser'
require_relative 'przn/code_highlighter'
require_relative 'przn/slide'
require_relative 'przn/presentation'
require_relative 'przn/terminal'
require_relative 'przn/renderer'
require_relative 'przn/presenter_renderer'
require_relative 'przn/audience_link'
require_relative 'przn/echoes_client'
require_relative 'przn/controller'
require_relative 'przn/screenshot_pdf_exporter'
require_relative 'przn/theme'

module Przn
  class Error < StandardError; end

  def self.start(file, theme: nil, theme_path: nil, start_at: nil)
    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    presentation.go_to(start_at - 1) if start_at
    terminal = Terminal.new
    base_dir = File.dirname(File.expand_path(file))
    renderer = Renderer.new(terminal, base_dir: base_dir, theme: theme)
    Controller.new(presentation, terminal, renderer,
                   source_file: file, theme_path: theme_path)
  end

  # Audience-side entry: opens the file, listens on `socket`, and renders
  # whatever slide the presenter sends a `goto` for. Notes are stripped.
  # Spawned by Echoes when the presenter requests an extended-display window.
  def self.audience(file, socket:, theme: nil)
    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    terminal = Terminal.new
    base_dir = File.dirname(File.expand_path(file))
    renderer = Renderer.new(terminal, base_dir: base_dir, theme: theme, mode: :audience)

    terminal.enter_alt_screen
    terminal.hide_cursor
    begin
      render = ->(idx, started_at) {
        presentation.go_to(idx)
        renderer.render(presentation.current_slide,
                        current: presentation.current,
                        total: presentation.total,
                        started_at: started_at)
      }
      render.call(0, nil)
      AudienceLink.serve(socket) do |msg|
        next unless msg[:type] == "goto" && msg[:index].is_a?(Integer)
        started_at = msg[:started_at] ? Time.at(msg[:started_at]) : nil
        render.call(msg[:index], started_at)
      end
    ensure
      terminal.write "\e]7772;bg-clear\a"
      terminal.write ImageUtil.kitty_clear_all if ImageUtil.kitty_terminal?
      terminal.show_cursor
      terminal.leave_alt_screen
    end
  end

  # Presenter-side entry: detects a second display via Echoes, spawns the
  # audience window on it, connects to the spawned process over a Unix
  # socket, and returns a Controller wired up to drive both sides.
  # Falls back to today's mirror-mode (`start`) when only one display is
  # attached or Echoes is not the host terminal.
  def self.present(file, theme: nil, theme_path: nil)
    info = EchoesClient.display_info
    if info.nil? || info.size < 2
      warn "przn: extended-display unavailable (no secondary display detected), falling back to mirror mode"
      return start(file, theme: theme)
    end

    socket_path = File.join(Dir.tmpdir, "przn-#{Process.pid}-#{SecureRandom.hex(4)}.sock")
    audience_argv = [File.expand_path($PROGRAM_NAME), '--audience', '--socket', socket_path]
    audience_argv += ['--theme', theme_path] if theme_path
    audience_argv << File.expand_path(file)
    EchoesClient.open_window(display: info.last[:index], argv: audience_argv)

    deadline = Time.now + 5
    sleep 0.1 until File.exist?(socket_path) || Time.now > deadline
    unless File.exist?(socket_path)
      warn "przn: audience window did not come up within 5s, falling back to mirror mode"
      return start(file, theme: theme)
    end

    link = AudienceLink.connect(socket_path)
    link.gets # discard the {"type":"ready"} handshake

    markdown = File.read(file)
    presentation = Parser.parse(markdown)
    terminal = Terminal.new
    base_dir = File.dirname(File.expand_path(file))
    renderer = PresenterRenderer.new(terminal, presentation: presentation, base_dir: base_dir, theme: theme)
    Controller.new(presentation, terminal, renderer, audience_link: link,
                   source_file: file, theme_path: theme_path)
  end
end
