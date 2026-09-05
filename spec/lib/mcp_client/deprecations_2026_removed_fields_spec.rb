# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 changelog, minor change 11: the revision removes the
# `notifications/elicitation/complete` notification AND the `elicitationId`
# field of URL-mode elicitation requests, both introduced in 2025-11-25.
# Under the Multi Round-Trip Requests pattern the client learns the outcome by
# retrying the original request, so a server-initiated completion signal and
# its correlation id no longer fit the protocol; a server that needs to
# correlate an elicitation across retries encodes its own identifier in
# `requestState`.
#
# So the host contract for a MODERN (2026-07-28) server must not carry a field
# the revision removed, and a non-conforming server must not be able to smuggle
# a correlation id into it. For a LEGACY (2025-11-25) server the field is part
# of the revision and the contract is unchanged.
#
# Every example here stays off the wire: no server is ever connected.
RSpec.describe 'MCP 2026-07-28 removed fields' do
  # The metadata hash a URL-mode elicitation handler is given.
  def url_metadata_seen_by(client, params, server)
    seen = nil
    handler = lambda do |_message, metadata|
      seen = metadata
      { 'action' => 'accept' }
    end
    client.instance_variable_set(:@elicitation_handler, handler)
    client.send(:handle_elicitation_request, 1, params, server)
    seen
  end

  let(:modern_server) { double('modern-server', name: 'modern', modern?: true) }
  let(:legacy_server) { double('legacy-server', name: 'legacy', modern?: false) }
  let(:accepting_handler) { ->(_message, _metadata) { { 'action' => 'accept' } } }
  let(:client) { MCPClient::Client.new(elicitation_handler: accepting_handler) }
  let(:url_params) do
    {
      'mode' => 'url',
      'message' => 'Visit to authorize',
      'url' => 'https://example.com/auth'
    }
  end

  describe 'the elicitationId of a URL-mode elicitation request' do
    context 'with a modern (2026-07-28) server' do
      it 'does not surface elicitationId to the host, even when the server sends one' do
        metadata = url_metadata_seen_by(client, url_params.merge('elicitationId' => 'elic-1'), modern_server)

        expect(metadata).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth' })
        expect(metadata).not_to have_key('elicitationId')
      end

      it 'does not surface elicitationId when the server sends none' do
        metadata = url_metadata_seen_by(client, url_params, modern_server)

        expect(metadata).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth' })
      end

      it 'keeps the same contract for a three-argument handler' do
        seen_metadata = nil
        seen_extra = nil
        handler = lambda do |_message, metadata, extra|
          seen_metadata = metadata
          seen_extra = extra
          { 'action' => 'accept' }
        end
        client.instance_variable_set(:@elicitation_handler, handler)

        params = url_params.merge('elicitationId' => 'elic-1', 'metadata' => { 'origin' => 'x' })
        client.send(:handle_elicitation_request, 1, params, modern_server)

        expect(seen_metadata).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth' })
        expect(seen_extra).to eq({ 'origin' => 'x' })
      end

      it 'logs that a server-sent elicitationId was ignored' do
        logger = client.instance_variable_get(:@logger)
        allow(logger).to receive(:warn)

        url_metadata_seen_by(client, url_params.merge('elicitationId' => 'elic-1'), modern_server)

        expect(logger).to have_received(:warn).with(/elicitationId/)
      end

      it 'does not log the server-chosen correlation id itself' do
        logger = client.instance_variable_get(:@logger)
        allow(logger).to receive(:warn)

        url_metadata_seen_by(client, url_params.merge('elicitationId' => 'secret-elic-1'), modern_server)

        expect(logger).not_to have_received(:warn).with(/secret-elic-1/)
      end

      it 'logs nothing about elicitationId when the server sends none' do
        logger = client.instance_variable_get(:@logger)
        allow(logger).to receive(:warn)

        url_metadata_seen_by(client, url_params, modern_server)

        expect(logger).not_to have_received(:warn).with(/elicitationId/)
      end

      it 'still answers the elicitation normally' do
        result = client.send(:handle_elicitation_request, 1, url_params.merge('elicitationId' => 'e'), modern_server)

        expect(result['action']).to eq('accept')
        expect(result).not_to have_key('content')
      end

      it 'leaves form-mode requests untouched' do
        seen = nil
        handler = lambda do |_message, schema|
          seen = schema
          { 'name' => 'Alice' }
        end
        client.instance_variable_set(:@elicitation_handler, handler)
        schema = { 'type' => 'object', 'properties' => { 'name' => { 'type' => 'string' } } }

        result = client.send(:handle_elicitation_request, 1, { 'message' => 'Name?', 'requestedSchema' => schema },
                             modern_server)

        expect(seen).to eq(schema)
        expect(result).to eq({ 'action' => 'accept', 'content' => { 'name' => 'Alice' } })
      end
    end

    context 'with a legacy (2025-11-25) server' do
      it 'surfaces elicitationId to the host unchanged' do
        metadata = url_metadata_seen_by(client, url_params.merge('elicitationId' => 'elic-1'), legacy_server)

        expect(metadata).to eq(
          { 'mode' => 'url', 'url' => 'https://example.com/auth', 'elicitationId' => 'elic-1' }
        )
      end

      it 'keeps the key present (nil) when the server sends none' do
        metadata = url_metadata_seen_by(client, url_params, legacy_server)

        expect(metadata).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth', 'elicitationId' => nil })
      end

      it 'keeps the same contract for a three-argument handler' do
        seen_metadata = nil
        handler = lambda do |_message, metadata, _extra|
          seen_metadata = metadata
          { 'action' => 'accept' }
        end
        client.instance_variable_set(:@elicitation_handler, handler)

        client.send(:handle_elicitation_request, 1, url_params.merge('elicitationId' => 'elic-1'), legacy_server)

        expect(seen_metadata).to eq(
          { 'mode' => 'url', 'url' => 'https://example.com/auth', 'elicitationId' => 'elic-1' }
        )
      end

      it 'logs nothing about elicitationId' do
        logger = client.instance_variable_get(:@logger)
        allow(logger).to receive(:warn)

        url_metadata_seen_by(client, url_params.merge('elicitationId' => 'elic-1'), legacy_server)

        expect(logger).not_to have_received(:warn).with(/elicitationId/)
      end
    end

    context 'when the era is not known (no server given)' do
      it 'keeps the 2025-11-25 contract' do
        metadata = url_metadata_seen_by(client, url_params.merge('elicitationId' => 'elic-1'), nil)

        expect(metadata).to eq(
          { 'mode' => 'url', 'url' => 'https://example.com/auth', 'elicitationId' => 'elic-1' }
        )
      end

      it 'is what a two-argument call still gets' do
        seen = nil
        handler = lambda do |_message, metadata|
          seen = metadata
          { 'action' => 'accept' }
        end
        client.instance_variable_set(:@elicitation_handler, handler)

        client.send(:handle_elicitation_request, 1, url_params.merge('elicitationId' => 'elic-1'))

        expect(seen).to have_key('elicitationId')
      end
    end
  end

  describe 'the registered elicitation callback' do
    # The transports call the registered callback with (request_id, params)
    # only, so the era has to reach the handler from the registration itself.
    def registered_callback_for(server)
      captured = nil
      allow(server).to receive(:on_elicitation_request) { |&block| captured = block }
      allow(server).to receive(:on_notification)
      allow(server).to receive(:respond_to?).with(:on_elicitation_request).and_return(true)
      allow(server).to receive(:respond_to?).with(:on_roots_list_request).and_return(false)
      allow(server).to receive(:respond_to?).with(:on_sampling_request).and_return(false)
      allow(server).to receive(:respond_to?).with(:modern?).and_return(true)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)

      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'true' }],
        elicitation_handler: @handler
      )
      captured
    end

    it 'carries the modern server through, so the host sees no elicitationId' do
      seen = nil
      @handler = lambda do |_message, metadata|
        seen = metadata
        { 'action' => 'accept' }
      end

      callback = registered_callback_for(modern_server)
      callback.call(1, url_params.merge('elicitationId' => 'elic-1'))

      expect(seen).not_to have_key('elicitationId')
    end

    # A modern server asks for an elicitation through the multi round-trip
    # pattern, which reaches the very same registered callback.
    it 'drops elicitationId on the multi round-trip path too' do
      seen = nil
      handler = lambda do |_message, metadata|
        seen = metadata
        { 'action' => 'accept' }
      end
      # Constructed, never connected: no process is spawned and no request
      # goes out.
      server = MCPClient::ServerStdio.new(command: 'true')
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      expect(server).to be_modern
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'true' }],
        elicitation_handler: handler
      )

      responses = server.send(
        :fulfil_input_requests,
        { 'k1' => { 'method' => 'elicitation/create',
                    'params' => url_params.merge('elicitationId' => 'elic-1') } },
        {}
      )

      expect(responses['k1']).to eq({ 'action' => 'accept' })
      expect(seen).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth' })
    end

    it 'carries the legacy server through, so the host still sees elicitationId' do
      seen = nil
      @handler = lambda do |_message, metadata|
        seen = metadata
        { 'action' => 'accept' }
      end

      callback = registered_callback_for(legacy_server)
      callback.call(1, url_params.merge('elicitationId' => 'elic-1'))

      expect(seen).to include('elicitationId' => 'elic-1')
    end

    # One client, two servers of different eras. A single-server client cannot
    # tell "the era of the server that asked" from "the era of some server
    # this client has": both readings give the same answer. Only a client
    # holding both can, and a host talking to a modern and a legacy server at
    # once is the ordinary case this contract exists for.
    context 'with a modern and a legacy server on the same client' do
      # The registered callbacks, in the order their servers were configured.
      def registered_callbacks_for(*servers)
        captured = {}
        servers.each do |server|
          allow(server).to receive(:on_elicitation_request) { |&block| captured[server.name] = block }
          allow(server).to receive(:on_notification)
          allow(server).to receive(:respond_to?).with(:on_elicitation_request).and_return(true)
          allow(server).to receive(:respond_to?).with(:on_roots_list_request).and_return(false)
          allow(server).to receive(:respond_to?).with(:on_sampling_request).and_return(false)
          allow(server).to receive(:respond_to?).with(:modern?).and_return(true)
        end
        allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)

        MCPClient::Client.new(
          mcp_server_configs: servers.map { { type: 'stdio', command: 'true' } },
          elicitation_handler: @handler
        )
        captured
      end

      # Both servers ask, interleaved, through the one handler the host
      # registered: each request is answered on its own server's contract.
      it 'gives each server\'s request the contract of that server' do
        seen = []
        @handler = lambda do |_message, metadata|
          seen << metadata
          { 'action' => 'accept' }
        end

        callbacks = registered_callbacks_for(modern_server, legacy_server)
        request = url_params.merge('elicitationId' => 'elic-1')
        callbacks['modern'].call(1, request)
        callbacks['legacy'].call(2, request)
        callbacks['modern'].call(3, request)

        expect(seen[0]).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth' })
        expect(seen[1]).to include('elicitationId' => 'elic-1')
        expect(seen[2]).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth' })
      end

      # The same client with the eras the other way round: an implementation
      # that reads one fixed server's era passes the order above by accident.
      it 'does so whichever era the client configured first' do
        seen = []
        @handler = lambda do |_message, metadata|
          seen << metadata
          { 'action' => 'accept' }
        end

        callbacks = registered_callbacks_for(legacy_server, modern_server)
        request = url_params.merge('elicitationId' => 'elic-1')
        callbacks['legacy'].call(1, request)
        callbacks['modern'].call(2, request)

        expect(seen[0]).to include('elicitationId' => 'elic-1')
        expect(seen[1]).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth' })
      end
    end
  end

  # The other field 2026-07-28 removed that a server could still try to push
  # at the client. A modern server is never sent `initialize`, which is the
  # only place a session id is captured, so the header is structurally
  # unreachable — this pins that, since nothing else feeds a modern response
  # that actually carries one.
  describe 'the Mcp-Session-Id header of a modern server response' do
    let(:url) { 'https://example.com/mcp' }

    def modern_result(method)
      case method
      when 'server/discover'
        { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
          'capabilities' => { 'tools' => {} }, 'ttlMs' => 0 }
      when 'tools/list'
        { 'resultType' => 'complete', 'tools' => [] }
      else
        raise "unexpected method #{method}"
      end
    end

    # Every response carries a session id the revision no longer has.
    def stub_session_pushing_modern_server
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << { headers: request.headers, body: body }
        { status: 200,
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => modern_result(body['method'])),
          headers: { 'Content-Type' => 'application/json', 'Mcp-Session-Id' => 'sess-1' } }
      end
      requests
    end

    it 'is never captured, echoed on a later request or terminated' do
      get_stub = stub_request(:get, url).to_return(status: 405, body: '')
      delete_stub = stub_request(:delete, url).to_return(status: 200, body: '')
      requests = stub_session_pushing_modern_server
      server = MCPClient::ServerStreamableHTTP.new(
        base_url: 'https://example.com', endpoint: '/mcp', retries: 0, read_timeout: 2
      )

      begin
        server.connect
        server.list_tools
        server.cleanup
      ensure
        server.cleanup
      end

      expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover tools/list])
      requests.each { |r| expect(r[:headers]).not_to have_key('Mcp-Session-Id') }
      expect(get_stub).not_to have_been_requested
      expect(delete_stub).not_to have_been_requested
    end
  end
end
