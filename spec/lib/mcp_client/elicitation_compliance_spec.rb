# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 elicitation compliance (client/elicitation.mdx):
# - Replies to elicitation/create MUST be JSON-RPC responses carrying an
#   ElicitResult (or a JSON-RPC error), on every transport.
# - "Server sends an elicitation/create request with a mode not declared in
#   client capabilities: -32602 (Invalid params)" (client MUST).
# - Internal failures must not be misreported as the user action "decline".
# - URL-mode results omit the content field (ElicitResult schema).
# - Clients SHOULD validate responses against the provided schema.
RSpec.describe 'Elicitation compliance (MCP 2025-11-25)' do
  describe MCPClient::Client do
    let(:params) do
      {
        'message' => 'Enter your name:',
        'requestedSchema' => {
          'type' => 'object',
          'properties' => { 'name' => { 'type' => 'string' } }
        }
      }
    end

    context 'when the server requests an undeclared or unknown mode' do
      it 'returns a -32602 Invalid params error' do
        client = described_class.new(elicitation_handler: ->(_m, _s) { { 'action' => 'accept' } })

        result = client.send(:handle_elicitation_request, 1, params.merge('mode' => 'voice'))

        expect(result['error']).to include('code' => -32_602)
        expect(result['error']['message']).to match(/mode/i)
        expect(result).not_to have_key('action')
      end
    end

    context 'when no elicitation handler is configured' do
      it 'returns a -32601 error instead of fabricating a user decline' do
        client = described_class.new

        result = client.send(:handle_elicitation_request, 1, params)

        expect(result['error']).to include('code' => -32_601)
        expect(result).not_to have_key('action')
      end
    end

    context 'when the elicitation handler raises' do
      it 'returns a -32603 internal error instead of fabricating a user decline' do
        handler = ->(_m, _s) { raise StandardError, 'boom' }
        client = described_class.new(elicitation_handler: handler)

        result = client.send(:handle_elicitation_request, 1, params)

        expect(result['error']).to include('code' => -32_603)
        expect(result).not_to have_key('action')
      end
    end

    context 'with a URL mode accept' do
      it 'omits the content field per the ElicitResult schema' do
        handler = ->(_m, _p) { { 'action' => 'accept', 'content' => { 'stray' => 'data' } } }
        client = described_class.new(elicitation_handler: handler)

        url_params = {
          'mode' => 'url',
          'message' => 'Visit to authorize',
          'url' => 'https://example.com/auth',
          'elicitationId' => 'elic-1'
        }
        result = client.send(:handle_elicitation_request, 2, url_params)

        expect(result['action']).to eq('accept')
        expect(result).not_to have_key('content')
      end
    end

    context 'when the handler returns content violating the requestedSchema' do
      it 'returns a -32603 error instead of transmitting invalid content' do
        handler = ->(_m, _s) { { 'name' => 123 } }
        client = described_class.new(elicitation_handler: handler)

        result = client.send(:handle_elicitation_request, 3, params)

        expect(result['error']).to include('code' => -32_603)
        expect(result['error']['message']).to match(/schema|validation/i)
      end
    end

    context 'when the server requests an unknown mode and no handler is configured' do
      it 'returns -32602 (mode check precedes handler check)' do
        client = described_class.new

        result = client.send(:handle_elicitation_request, 1, params.merge('mode' => 'voice'))

        expect(result['error']).to include('code' => -32_602)
      end
    end

    context 'when the handler returns scalar content' do
      it 'returns -32603 instead of sending non-object content' do
        handler = ->(_m, _s) { 'yes' }
        client = described_class.new(elicitation_handler: handler)

        result = client.send(:handle_elicitation_request, 5, params)

        expect(result['error']).to include('code' => -32_603)
      end
    end

    context 'when the handler uses symbol keys in URL mode' do
      it 'still omits the content field' do
        handler = ->(_m, _p) { { action: :accept, content: { 'stray' => 'data' } } }
        client = described_class.new(elicitation_handler: handler)

        url_params = { 'mode' => 'url', 'message' => 'Visit', 'url' => 'https://e.com', 'elicitationId' => 'e2' }
        result = client.send(:handle_elicitation_request, 6, url_params)

        expect(result['action']).to eq('accept')
        expect(result).not_to have_key('content')
        expect(result).not_to have_key(:content)
      end
    end

    context 'when the handler attaches content to a decline' do
      it 'strips content (only accept results carry content)' do
        handler = ->(_m, _s) { { 'action' => 'decline', 'content' => { 'name' => 'x' } } }
        client = described_class.new(elicitation_handler: handler)

        result = client.send(:handle_elicitation_request, 7, params)

        expect(result).to eq({ 'action' => 'decline' })
      end
    end

    context 'when the handler returns conforming content' do
      it 'returns the accept result unchanged' do
        handler = ->(_m, _s) { { 'name' => 'Alice' } }
        client = described_class.new(elicitation_handler: handler)

        result = client.send(:handle_elicitation_request, 4, params)

        expect(result).to eq({ 'action' => 'accept', 'content' => { 'name' => 'Alice' } })
      end
    end
  end

  describe MCPClient::ElicitationValidator do
    def schema_for(prop)
      { 'type' => 'object', 'properties' => { 'value' => prop } }
    end

    it 'flags a string that violates the email format' do
      errors = described_class.validate_content(
        { 'value' => 'not-an-email' }, schema_for({ 'type' => 'string', 'format' => 'email' })
      )
      expect(errors).not_to be_empty
    end

    it 'accepts a valid email format value' do
      errors = described_class.validate_content(
        { 'value' => 'user@example.com' }, schema_for({ 'type' => 'string', 'format' => 'email' })
      )
      expect(errors).to be_empty
    end

    it 'flags a string that violates the uri format' do
      errors = described_class.validate_content(
        { 'value' => 'not a uri' }, schema_for({ 'type' => 'string', 'format' => 'uri' })
      )
      expect(errors).not_to be_empty
    end

    it 'flags a string that violates the date format' do
      errors = described_class.validate_content(
        { 'value' => '2026-13-45' }, schema_for({ 'type' => 'string', 'format' => 'date' })
      )
      expect(errors).not_to be_empty
    end

    it 'accepts a valid date-time format value' do
      errors = described_class.validate_content(
        { 'value' => '2026-07-20T12:34:56Z' }, schema_for({ 'type' => 'string', 'format' => 'date-time' })
      )
      expect(errors).to be_empty
    end
  end

  describe 'declared elicitation capability' do
    it 'declares both supported modes (form and url) when a callback is registered' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      server.on_elicitation_request { |_id, _params| { 'action' => 'decline' } }
      params = server.send(:initialization_params)

      expect(params['capabilities']['elicitation']).to eq({ 'form' => {}, 'url' => {} })
    end
  end

  describe MCPClient::ServerStreamableHTTP, 'wire format' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }

    let(:server) do
      described_class.new(base_url: base_url, endpoint: endpoint, name: 'elic-wire-test')
    end

    after { server.cleanup }

    before do
      server.instance_variable_set(:@session_id, 'test-session-123')
    end

    it 'replies to elicitation/create with a standard JSON-RPC response' do
      server.send(:on_elicitation_request) do |_req_id, _params|
        { 'action' => 'accept', 'content' => { 'name' => 'Alice' } }
      end

      response_stub = stub_request(:post, "#{base_url}#{endpoint}")
                      .with(
                        body: {
                          'jsonrpc' => '2.0',
                          'id' => 456,
                          'result' => { 'action' => 'accept', 'content' => { 'name' => 'Alice' } }
                        }.to_json
                      )
                      .to_return(status: 200, body: '')

      request = {
        'jsonrpc' => '2.0',
        'id' => 456,
        'method' => 'elicitation/create',
        'params' => { 'message' => 'Enter your name:' }
      }
      server.send(:handle_server_message, JSON.generate(request))

      deadline = Time.now + 2
      sleep 0.05 until response_stub.to_s.include?('was requested 1 time') || Time.now > deadline

      expect(response_stub).to have_been_requested.once
    end

    it 'replies with a JSON-RPC error when the callback yields an error result' do
      server.send(:on_elicitation_request) do |_req_id, _params|
        { 'error' => { 'code' => -32_602, 'message' => "Elicitation mode 'voice' is not supported" } }
      end

      error_stub = stub_request(:post, "#{base_url}#{endpoint}")
                   .with(
                     body: hash_including(
                       'jsonrpc' => '2.0',
                       'id' => 457,
                       'error' => hash_including('code' => -32_602)
                     )
                   )
                   .to_return(status: 200, body: '')

      request = {
        'jsonrpc' => '2.0',
        'id' => 457,
        'method' => 'elicitation/create',
        'params' => { 'mode' => 'voice', 'message' => 'Speak now' }
      }
      server.send(:handle_server_message, JSON.generate(request))

      deadline = Time.now + 2
      sleep 0.05 until error_stub.to_s.include?('was requested 1 time') || Time.now > deadline

      expect(error_stub).to have_been_requested.once
    end
  end

  describe 'error results on stdio and SSE transports' do
    it 'stdio sends a JSON-RPC error response for an error-shaped elicitation result' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      expect(server).to receive(:send_message).with(
        hash_including('jsonrpc' => '2.0', 'id' => 9, 'error' => hash_including('code' => -32_602))
      )

      server.send(:send_elicitation_response, 9, { 'error' => { 'code' => -32_602, 'message' => 'bad mode' } })
    end

    it 'SSE sends a JSON-RPC error response for an error-shaped elicitation result' do
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
      expect(server).to receive(:send_error_response).with(9, -32_602, 'bad mode')

      server.send(:send_elicitation_response, 9, { 'error' => { 'code' => -32_602, 'message' => 'bad mode' } })
    end
  end
end
