# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::HttpTransportBase do
  # Create a test class that includes the module for testing
  let(:test_class) do
    Class.new do
      include MCPClient::HttpTransportBase

      attr_accessor :session_id, :base_url, :endpoint, :headers, :mutex, :logger, :max_retries, :retry_backoff,
                    :read_timeout

      def initialize(logger)
        @session_id = nil
        @base_url = 'https://example.com'
        @endpoint = '/mcp'
        @headers = { 'Content-Type' => 'application/json' }
        @mutex = Monitor.new
        @logger = logger
        @max_retries = 3
        @retry_backoff = 1
        @read_timeout = 30
        @request_id = 0
      end

      # Stub parse_response since it's abstract in the base module
      def parse_response(_response)
        { 'result' => 'test' }
      end

      # Stub ensure_connected
      def ensure_connected
        # no-op for testing
      end

      # Create a stub HTTP connection for testing
      def create_http_connection
        instance_double('Faraday::Connection')
      end

      # Stub log_response
      def log_response(response)
        # no-op for testing
      end

      # Make private methods accessible for testing
      def test_valid_session_id?(session_id)
        valid_session_id?(session_id)
      end

      def test_valid_server_url?(url)
        valid_server_url?(url)
      end

      def test_handle_http_error_response(response)
        handle_http_error_response(response)
      end

      def test_initialization_params
        initialization_params
      end
    end
  end

  let(:logger) { instance_double('Logger') }
  let(:transport) do
    # Allow logger to receive any method without actually logging
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(logger).to receive(:info)
    test_class.new(logger)
  end

  describe '#terminate_session' do
    let(:connection) { instance_double('Faraday::Connection') }
    let(:request_builder) { instance_double('Faraday::Request') }
    let(:response) { instance_double('Faraday::Response') }

    before do
      allow(transport).to receive(:http_connection).and_return(connection)
      allow(connection).to receive(:delete).and_yield(request_builder).and_return(response)
      allow(request_builder).to receive(:headers).and_return({})
      allow(request_builder.headers).to receive(:[]=)
    end

    context 'when session ID is present' do
      before do
        transport.session_id = 'test-session-123'
      end

      it 'sends HTTP DELETE request with session header' do
        allow(response).to receive(:success?).and_return(true)

        result = transport.terminate_session

        expect(connection).to have_received(:delete).with('/mcp')
        expect(request_builder.headers).to have_received(:[]=).with('Mcp-Session-Id', 'test-session-123')
        expect(result).to be true
        expect(transport.session_id).to be_nil
      end

      it 'returns false on HTTP error but clears session ID' do
        allow(response).to receive(:success?).and_return(false)
        allow(response).to receive(:status).and_return(400)

        result = transport.terminate_session

        expect(result).to be false
        expect(transport.session_id).to be_nil
      end

      it 'handles Faraday errors gracefully' do
        allow(connection).to receive(:delete).and_raise(Faraday::ConnectionFailed.new('Connection failed'))

        result = transport.terminate_session

        expect(result).to be false
        expect(transport.session_id).to be_nil
      end
    end

    context 'when no session ID is present' do
      it 'returns true without making a request' do
        result = transport.terminate_session

        expect(connection).not_to have_received(:delete)
        expect(result).to be true
      end
    end
  end

  describe '#valid_session_id?' do
    context 'with valid session IDs' do
      valid_session_ids = [
        'abc123def456',           # alphanumeric
        'session_id_123',         # with underscores
        'sess-123-abc_def',       # with hyphens and underscores
        'a1b2c3d4e5f6g7h8', # mixed alphanumeric
        '12345678',               # minimum length (8 chars)
        'A' * 128                 # maximum length (128 chars)
      ]

      valid_session_ids.each do |session_id|
        it "accepts valid session ID: '#{session_id.length > 20 ? "#{session_id[0..17]}..." : session_id}'" do
          expect(transport.test_valid_session_id?(session_id)).to be true
        end
      end
    end

    context 'with invalid session IDs' do
      invalid_session_ids = [
        '',                       # empty string
        'short',                  # too short (< 8 chars)
        'A' * 129,               # too long (> 128 chars)
        'session@id',            # invalid character (@)
        'session id',            # space character
        'session.id',            # dot character
        'session/id',            # slash character
        'session%id',            # percent character
        'session#id',            # hash character
        'session+id',            # plus character
        'session=id',            # equals character
        'session?id',            # question mark
        'session&id',            # ampersand
        'session|id',            # pipe character
        'session;id',            # semicolon
        'session:id',            # colon
        'session<id>',           # angle brackets
        'session[id]',           # square brackets
        'session{id}',           # curly brackets
        'session(id)',           # parentheses
        'session"id"',           # quotes
        "session'id'",           # single quotes
        'session`id`',           # backticks
        'session~id',            # tilde
        'session!id',            # exclamation mark
        'session$id',            # dollar sign
        'session^id',            # caret
        'session*id'             # asterisk
      ]

      invalid_session_ids.each do |session_id|
        it "rejects invalid session ID: '#{session_id.length > 20 ? "#{session_id[0..17]}..." : session_id}'" do
          expect(transport.test_valid_session_id?(session_id)).to be false
        end
      end
    end

    context 'with non-string input' do
      [nil, 123, [], {}, Object.new, true, false].each do |input|
        it "rejects non-string input: #{input.class}" do
          expect(transport.test_valid_session_id?(input)).to be false
        end
      end
    end
  end

  describe '#valid_server_url?' do
    context 'with valid URLs' do
      valid_urls = [
        'http://localhost',
        'http://localhost:3000',
        'https://api.example.com',
        'http://127.0.0.1:8080',
        'https://subdomain.example.com',
        'https://example.com/path',
        'https://example.com/path/to/resource',
        'http://192.168.1.1',
        'https://api-v2.example.com',
        'http://example.com:8080/api/v1'
      ]

      valid_urls.each do |url|
        it "accepts valid URL: '#{url}'" do
          expect(transport.test_valid_server_url?(url)).to be true
        end
      end
    end

    context 'with invalid URLs' do
      invalid_urls = [
        'ftp://example.com',         # invalid protocol
        'file:///path/to/file',      # file protocol
        'javascript:alert(1)',       # javascript protocol
        'data:text/html,<h1>test</h1>', # data protocol
        'mailto:test@example.com',   # mailto protocol
        'ssh://user@example.com',    # ssh protocol
        'telnet://example.com',      # telnet protocol
        'ldap://example.com',        # ldap protocol
        'not-a-url',                 # invalid format
        '',                          # empty string
        'http://',                   # incomplete URL
        'https://',                  # incomplete URL
        'http:///path',              # missing host
        'https:///path',             # missing host
        '//example.com',             # protocol-relative (no scheme)
        'example.com',               # missing protocol
        'www.example.com'            # missing protocol
      ]

      invalid_urls.each do |url|
        it "rejects invalid URL: '#{url}'" do
          expect(transport.test_valid_server_url?(url)).to be false
        end
      end
    end

    context 'with security warnings' do
      it 'logs warning for 0.0.0.0 binding but still accepts it' do
        expect(transport.test_valid_server_url?('http://0.0.0.0:3000')).to be true
        expect(transport.logger).to have_received(:warn).with(/0.0.0.0.*insecure.*127.0.0.1/)
      end
    end

    context 'with non-string input' do
      [nil, 123, [], {}, Object.new, true, false].each do |input|
        it "rejects non-string input: #{input.class}" do
          expect(transport.test_valid_server_url?(input)).to be false
        end
      end
    end

    context 'with malformed URLs that raise URI::InvalidURIError' do
      malformed_urls = [
        'http://[invalid-ipv6',
        'https://user:pass@[::1:3000',
        'http://exam ple.com',        # space in hostname
        'https://exam\nple.com',      # newline in hostname
        'http://exa\tmple.com',       # tab in hostname
        'https://exam\rple.com'       # carriage return in hostname
      ]

      malformed_urls.each do |url|
        it "rejects malformed URL that raises URI error: '#{url}'" do
          expect(transport.test_valid_server_url?(url)).to be false
        end
      end
    end
  end

  describe 'retry functionality' do
    let(:request) { { 'method' => 'test', 'id' => 1 } }

    before do
      allow(transport).to receive(:ensure_connected)
      allow(transport).to receive(:send_jsonrpc_request).and_return({ 'result' => 'success' })
      transport.instance_variable_set(:@request_id, 0)
    end

    it 'includes retry logic in rpc_request' do
      result = transport.rpc_request('test', {})
      expect(result).to eq({ 'result' => 'success' })
    end

    it 'builds JSON-RPC request with correct structure' do
      allow(transport).to receive(:build_jsonrpc_request).and_call_original

      transport.rpc_request('test_method', { param: 'value' })

      expect(transport).to have_received(:build_jsonrpc_request).with(
        'test_method',
        { param: 'value' },
        1
      )
    end
  end

  describe 'notification functionality' do
    before do
      allow(transport).to receive(:ensure_connected)
      allow(transport).to receive(:send_http_request)
      allow(transport).to receive(:build_jsonrpc_notification).and_call_original
    end

    it 'sends notification without expecting response' do
      transport.rpc_notify('notification_method', { data: 'test' })

      expect(transport).to have_received(:build_jsonrpc_notification).with(
        'notification_method',
        { data: 'test' }
      )
      expect(transport).to have_received(:send_http_request)
    end

    it 'handles errors in notifications gracefully' do
      allow(transport).to receive(:send_http_request).and_raise(Faraday::ConnectionFailed.new('Failed'))

      expect do
        transport.rpc_notify('test', {})
      end.to raise_error(MCPClient::Errors::TransportError, /Failed to send notification/)
    end
  end

  describe 'error handling' do
    let(:response) { instance_double('Faraday::Response') }

    before do
      allow(response).to receive(:respond_to?).with(:reason_phrase).and_return(true)
      allow(response).to receive(:reason_phrase).and_return('Test Error')
    end

    describe '#handle_http_error_response' do
      context 'with authentication errors' do
        [401, 403].each do |status|
          it "raises ConnectionError for HTTP #{status}" do
            allow(response).to receive(:status).and_return(status)

            expect do
              transport.test_handle_http_error_response(response)
            end.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed.*#{status}/)
          end
        end
      end

      context 'with client errors' do
        [400, 404, 422, 429].each do |status|
          it "raises ServerError for HTTP #{status}" do
            allow(response).to receive(:status).and_return(status)

            expect do
              transport.test_handle_http_error_response(response)
            end.to raise_error(MCPClient::Errors::ServerError, /Client error.*#{status}.*Test Error/)
          end
        end
      end

      context 'with server errors' do
        [500, 502, 503, 504].each do |status|
          it "raises ServerError for HTTP #{status}" do
            allow(response).to receive(:status).and_return(status)

            expect do
              transport.test_handle_http_error_response(response)
            end.to raise_error(MCPClient::Errors::ServerError, /Server error.*#{status}.*Test Error/)
          end
        end
      end

      context 'with other error codes' do
        it 'raises ServerError for unexpected status codes' do
          allow(response).to receive(:status).and_return(418) # I'm a teapot

          expect do
            transport.test_handle_http_error_response(response)
          end.to raise_error(MCPClient::Errors::ServerError, /Client error.*418.*Test Error/)
        end
      end

      context 'when response does not have reason_phrase' do
        before do
          allow(response).to receive(:respond_to?).with(:reason_phrase).and_return(false)
        end

        it 'handles missing reason phrase gracefully' do
          allow(response).to receive(:status).and_return(500)

          expect do
            transport.test_handle_http_error_response(response)
          end.to raise_error(MCPClient::Errors::ServerError, /Server error.*500$/)
        end
      end
    end
  end

  describe 'initialization parameters' do
    it 'generates correct initialization parameters' do
      params = transport.test_initialization_params

      expect(params).to include(
        'protocolVersion' => MCPClient::HTTP_PROTOCOL_VERSION,
        'capabilities' => {},
        'clientInfo' => {
          'name' => 'ruby-mcp-client',
          'version' => MCPClient::VERSION
        }
      )
    end
  end
end
