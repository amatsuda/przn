# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class AudienceLinkTest < Test::Unit::TestCase
  test 'presenter goto messages are received by the audience in order' do
    Dir.mktmpdir do |dir|
      sock = File.join(dir, 'p.sock')
      received = []

      audience = Thread.new do
        Przn::AudienceLink.serve(sock) do |msg|
          received << msg
        end
      end

      # Wait for the server to bind the socket.
      Timeout.timeout(2) { sleep 0.01 until File.exist?(sock) }
      client = Przn::AudienceLink.connect(sock)
      assert_equal({type: 'ready'}, JSON.parse(client.gets, symbolize_names: true))

      Przn::AudienceLink.send(client, type: 'goto', index: 0)
      Przn::AudienceLink.send(client, type: 'goto', index: 1)
      Przn::AudienceLink.send(client, type: 'goto', index: 2)
      Przn::AudienceLink.send(client, type: 'quit')

      audience.join(2)
      client.close

      assert_equal(
        [
          {type: 'goto', index: 0},
          {type: 'goto', index: 1},
          {type: 'goto', index: 2},
        ],
        received,
      )
    end
  end
end
