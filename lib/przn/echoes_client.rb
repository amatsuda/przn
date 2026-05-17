# frozen_string_literal: true

require 'io/console'
require 'json'
require 'timeout'

module Przn
  # Thin wrappers around Echoes-specific OSC 7772 commands the presenter uses
  # to set up extended-display mode. Other terminals ignore OSC 7772, so each
  # method silently fails (returns nil / false) when not running inside Echoes.
  module EchoesClient
    OSC = "\e]7772"
    BEL = "\a"
    REPLY_TIMEOUT_S = 0.5

    module_function

    # Ask Echoes how many displays are attached and a tiny descriptor for each.
    # Returns an Array of Hashes like [{index: 0, w: 1920, h: 1080}, ...] or
    # nil when no reply arrives within the timeout (non-Echoes terminal, or
    # an Echoes that doesn't speak this command yet).
    def display_info(io_in: $stdin, io_out: $stdout)
      io_out.write("#{OSC};display-info#{BEL}")
      io_out.flush if io_out.respond_to?(:flush)
      reply = read_osc_reply(io_in)
      return nil unless reply
      JSON.parse(reply, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end

    # Open a new Echoes window on the given display, running `argv` (an
    # Array of strings — argv[0] is the executable). `fullscreen:` is a hint.
    # Returns true if the request was emitted; nothing in the protocol confirms
    # success synchronously.
    def open_window(display:, argv:, fullscreen: true, io_out: $stdout)
      # `pack('m0')` is strict (no-newline) base64 — same as
      # Base64.strict_encode64 but without pulling in the base64 stdlib,
      # which is no longer a default gem in Ruby 3.4+.
      payload = [JSON.generate(argv)].pack('m0')
      args = "display=#{display}:program=#{payload}:fullscreen=#{fullscreen ? 'yes' : 'no'}"
      io_out.write("#{OSC};open-window;#{args}#{BEL}")
      io_out.flush if io_out.respond_to?(:flush)
      true
    end

    # Read an OSC reply up to ST or BEL. Returns the payload string or nil on
    # timeout. Echoes replies follow the same `\e]7772;...\a` shape it accepts.
    #
    # Stdin defaults to canonical (line-buffered) mode in a shell context, so
    # `getc` would block waiting for a newline that an OSC reply never sends.
    # Put the input in raw mode for the duration of the read; IO#raw saves and
    # restores termios automatically.
    def read_osc_reply(io_in)
      if io_in.respond_to?(:raw) && io_in.respond_to?(:tty?) && io_in.tty?
        io_in.raw { read_osc_reply_inner(io_in) }
      else
        read_osc_reply_inner(io_in)
      end
    end

    def read_osc_reply_inner(io_in)
      Timeout.timeout(REPLY_TIMEOUT_S) do
        buf = +""
        loop do
          c = io_in.getc
          return nil if c.nil?
          break if c == BEL
          if c == "\e"
            nxt = io_in.getc
            break if nxt == "\\"
            buf << c << nxt
          else
            buf << c
          end
        end
        buf.sub(/\A\e?\]?7772;[\w-]+;/, '')
      end
    rescue Timeout::Error
      nil
    end
  end
end
