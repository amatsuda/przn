# frozen_string_literal: true

require 'json'
require 'socket'

module Przn
  # Tiny line-delimited JSON protocol over a Unix-domain socket, joining the
  # presenter and audience `przn` processes in extended-display mode.
  #
  # Messages currently exchanged:
  #   {"type": "ready"}                  audience -> presenter
  #   {"type": "goto", "index": N}       presenter -> audience
  #   {"type": "quit"}                   presenter -> audience
  module AudienceLink
    module_function

    # Audience-side: open a UNIXServer at `path`, wait for the presenter to
    # connect, then yield each decoded message until EOF or {"type":"quit"}.
    # The socket file is unlinked on exit.
    def serve(path)
      File.unlink(path) if File.exist?(path)
      server = UNIXServer.new(path)
      client = server.accept
      send(client, {type: "ready"})
      while (line = client.gets)
        msg = JSON.parse(line.chomp, symbolize_names: true)
        break if msg[:type] == "quit"
        yield msg
      end
    rescue Errno::EPIPE, EOFError, IOError
      # Presenter went away; let the caller exit cleanly.
    ensure
      client&.close
      server&.close
      File.unlink(path) if path && File.exist?(path)
    end

    # Presenter-side: connect to an audience socket at `path` and return a
    # client object that responds to `#send` and `#close`. Caller drives the
    # protocol from the controller.
    def connect(path)
      UNIXSocket.new(path)
    end

    def send(io, msg)
      io.puts(JSON.generate(msg))
    rescue Errno::EPIPE, IOError
      # Other side hung up — caller decides whether to keep going.
    end
  end
end
