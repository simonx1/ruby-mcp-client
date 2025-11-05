# frozen_string_literal: true

require 'spec_helper'
require 'mcp_client/auth/browser_oauth'

RSpec.describe MCPClient::Auth::BrowserOAuth do
  let(:server_url) { 'https://mcp.example.com' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:auth_url) { 'https://auth.example.com/authorize?client_id=123' }
  let(:logger) { instance_double('Logger') }
  let(:storage) { instance_double('MCPClient::Auth::OAuthProvider::MemoryStorage') }
  let(:oauth_provider) do
    instance_double(
      'MCPClient::Auth::OAuthProvider',
      server_url: server_url,
      redirect_uri: redirect_uri
    )
  end

  subject(:browser_oauth) do
    described_class.new(
      oauth_provider,
      callback_port: 8080,
      callback_path: '/callback',
      logger: logger
    )
  end

  before do
    allow(logger).to receive(:debug)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
  end

  describe '#initialize' do
    it 'sets OAuth provider' do
      expect(browser_oauth.oauth_provider).to eq(oauth_provider)
    end

    it 'sets callback port' do
      expect(browser_oauth.callback_port).to eq(8080)
    end

    it 'sets callback path' do
      expect(browser_oauth.callback_path).to eq('/callback')
    end

    it 'uses default callback port' do
      oauth = described_class.new(oauth_provider)
      expect(oauth.callback_port).to eq(8080)
    end

    it 'uses default callback path' do
      oauth = described_class.new(oauth_provider)
      expect(oauth.callback_path).to eq('/callback')
    end

    context 'when redirect_uri does not match callback server' do
      let(:oauth_provider) do
        instance_double(
          'MCPClient::Auth::OAuthProvider',
          server_url: server_url,
          redirect_uri: 'http://localhost:9000/auth'
        )
      end

      it 'warns about mismatch' do
        allow(oauth_provider).to receive(:redirect_uri=)

        expect(logger).to receive(:warn).with(/doesn't match/)

        described_class.new(
          oauth_provider,
          callback_port: 8080,
          callback_path: '/callback',
          logger: logger
        )
      end

      it 'updates OAuth provider redirect_uri' do
        expect(oauth_provider).to receive(:redirect_uri=).with('http://localhost:8080/callback')

        described_class.new(
          oauth_provider,
          callback_port: 8080,
          callback_path: '/callback',
          logger: logger
        )
      end
    end
  end

  describe '#authenticate' do
    let(:auth_code) { 'auth_code_123' }
    let(:state) { 'state_abc' }
    let(:token) do
      MCPClient::Auth::Token.new(
        access_token: 'access_token_123',
        token_type: 'Bearer',
        expires_in: 3600
      )
    end

    before do
      allow(oauth_provider).to receive(:start_authorization_flow).and_return(auth_url)
      allow(oauth_provider).to receive(:complete_authorization_flow).and_return(token)
    end

    context 'when port is already in use' do
      it 'raises ConnectionError with helpful message' do
        allow(TCPServer).to receive(:new).and_raise(Errno::EADDRINUSE)

        expect do
          browser_oauth.authenticate
        end.to raise_error(
          MCPClient::Errors::ConnectionError,
          /port 8080 is already in use/
        )
      end
    end

    context 'when server fails to start' do
      it 'raises ConnectionError' do
        allow(TCPServer).to receive(:new).and_raise(StandardError.new('Network error'))

        expect do
          browser_oauth.authenticate
        end.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Failed to start OAuth callback server/
        )
      end
    end

    context 'when authentication times out' do
      it 'raises Timeout::Error' do
        tcp_server = instance_double('TCPServer')
        allow(TCPServer).to receive(:new).and_return(tcp_server)
        allow(tcp_server).to receive(:close)

        # Mock IO.select to never return readable (simulating timeout)
        allow(IO).to receive(:select).and_return(nil)

        expect do
          browser_oauth.authenticate(timeout: 0.1, auto_open_browser: false)
        end.to raise_error(Timeout::Error, /timed out after/)
      end
    end

    context 'when OAuth callback returns error' do
      it 'raises ConnectionError with error description' do
        tcp_server = instance_double('TCPServer')
        client_socket = instance_double('TCPSocket')

        allow(TCPServer).to receive(:new).and_return(tcp_server)
        allow(IO).to receive(:select).and_return([[tcp_server]])
        allow(tcp_server).to receive(:accept).and_return(client_socket)
        allow(tcp_server).to receive(:close)

        # Mock socket operations
        allow(client_socket).to receive(:setsockopt)
        allow(client_socket).to receive(:gets).and_return(
          "GET /callback?error=access_denied&error_description=User+denied HTTP/1.1\r\n",
          "\r\n", # End of headers
          nil
        )
        allow(client_socket).to receive(:print)
        allow(client_socket).to receive(:close)

        expect do
          browser_oauth.authenticate(timeout: 1, auto_open_browser: false)
        end.to raise_error(
          MCPClient::Errors::ConnectionError,
          /User denied/
        )
      end
    end

    context 'when callback is missing required parameters' do
      it 'raises ConnectionError' do
        tcp_server = instance_double('TCPServer')
        client_socket = instance_double('TCPSocket')

        allow(TCPServer).to receive(:new).and_return(tcp_server)
        allow(IO).to receive(:select).and_return([[tcp_server]])
        allow(tcp_server).to receive(:accept).and_return(client_socket)
        allow(tcp_server).to receive(:close)

        # Mock socket operations - missing state parameter
        allow(client_socket).to receive(:setsockopt)
        allow(client_socket).to receive(:gets).and_return(
          "GET /callback?code=abc123 HTTP/1.1\r\n",
          "\r\n",
          nil
        )
        allow(client_socket).to receive(:print)
        allow(client_socket).to receive(:close)

        expect do
          browser_oauth.authenticate(timeout: 1, auto_open_browser: false)
        end.to raise_error(
          MCPClient::Errors::ConnectionError,
          /missing code or state parameter/
        )
      end
    end
  end

  describe '#open_browser' do
    context 'on macOS' do
      it 'uses open command' do
        allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return('darwin')
        expect(browser_oauth).to receive(:system).with('open', auth_url).and_return(true)

        browser_oauth.send(:open_browser, auth_url)
      end
    end

    context 'on Linux' do
      it 'uses xdg-open command' do
        allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return('linux')
        expect(browser_oauth).to receive(:system).with('xdg-open', auth_url).and_return(true)

        browser_oauth.send(:open_browser, auth_url)
      end
    end

    context 'on Windows' do
      it 'uses start command' do
        allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return('mingw')
        expect(browser_oauth).to receive(:system).with('start', auth_url).and_return(true)

        browser_oauth.send(:open_browser, auth_url)
      end
    end

    context 'on unknown OS' do
      it 'logs warning and returns false' do
        allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return('unknown')

        expect(logger).to receive(:warn).with(/Unknown operating system/)
        result = browser_oauth.send(:open_browser, auth_url)

        expect(result).to be false
      end
    end

    context 'when browser fails to open' do
      it 'logs warning and returns false' do
        allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return('darwin')
        allow(browser_oauth).to receive(:system).and_raise(StandardError.new('Command failed'))

        expect(logger).to receive(:warn).with(/Failed to open browser/)
        result = browser_oauth.send(:open_browser, auth_url)

        expect(result).to be false
      end
    end
  end

  describe '#parse_query_params' do
    it 'parses simple query string' do
      result = browser_oauth.send(:parse_query_params, 'code=123&state=abc')

      expect(result).to eq('code' => '123', 'state' => 'abc')
    end

    it 'handles URL encoded values' do
      result = browser_oauth.send(:parse_query_params, 'message=Hello+World&error=access%20denied')

      expect(result).to eq('message' => 'Hello World', 'error' => 'access denied')
    end

    it 'handles empty values' do
      result = browser_oauth.send(:parse_query_params, 'code=123&empty=')

      expect(result).to eq('code' => '123', 'empty' => '')
    end

    it 'handles empty query string' do
      result = browser_oauth.send(:parse_query_params, '')

      expect(result).to eq({})
    end

    it 'handles parameters without values' do
      result = browser_oauth.send(:parse_query_params, 'code=123&flag&state=abc')

      expect(result).to include('code' => '123', 'state' => 'abc', 'flag' => '')
    end
  end

  describe '#send_http_response' do
    let(:client) { instance_double('TCPSocket') }

    it 'sends 200 OK response' do
      response = nil
      expect(client).to receive(:print) do |arg|
        response = arg
      end

      browser_oauth.send(:send_http_response, client, 200, 'text/html', 'Success')

      expect(response).to match(/HTTP\/1\.1 200 OK/)
      expect(response).to match(/Content-Type: text\/html/)
      expect(response).to match(/Success/)
    end

    it 'sends 400 Bad Request response' do
      response = nil
      expect(client).to receive(:print) do |arg|
        response = arg
      end

      browser_oauth.send(:send_http_response, client, 400, 'text/plain', 'Error')

      expect(response).to match(/HTTP\/1\.1 400 Bad Request/)
      expect(response).to match(/Error/)
    end

    it 'sends 404 Not Found response' do
      response = nil
      expect(client).to receive(:print) do |arg|
        response = arg
      end

      browser_oauth.send(:send_http_response, client, 404, 'text/plain', 'Not Found')

      expect(response).to match(/HTTP\/1\.1 404 Not Found/)
      expect(response).to match(/Not Found/)
    end

    it 'includes correct Content-Length' do
      body = 'Test response body'
      response = nil
      expect(client).to receive(:print) do |arg|
        response = arg
      end

      browser_oauth.send(:send_http_response, client, 200, 'text/plain', body)

      expect(response).to match(/Content-Length: #{body.bytesize}/)
    end

    it 'includes Connection: close header' do
      response = nil
      expect(client).to receive(:print) do |arg|
        response = arg
      end

      browser_oauth.send(:send_http_response, client, 200, 'text/plain', 'Body')

      expect(response).to match(/Connection: close/)
    end
  end

  describe 'HTML pages' do
    describe '#success_page' do
      let(:html) { browser_oauth.send(:success_page) }

      it 'includes success icon' do
        expect(html).to include('✅')
      end

      it 'includes success message' do
        expect(html).to include('Authentication Successful')
      end

      it 'includes instructions to close window' do
        expect(html).to include('close this window')
      end

      it 'is valid HTML' do
        expect(html).to include('<!DOCTYPE html>')
        expect(html).to include('</html>')
      end

      it 'includes CSS styling' do
        expect(html).to include('<style>')
      end
    end

    describe '#error_page' do
      let(:error_message) { 'Access denied by user' }
      let(:html) { browser_oauth.send(:error_page, error_message) }

      it 'includes error icon' do
        expect(html).to include('❌')
      end

      it 'includes error message' do
        expect(html).to include('Authentication Failed')
      end

      it 'escapes HTML in error message' do
        html = browser_oauth.send(:error_page, '<script>alert("xss")</script>')
        expect(html).not_to include('<script>')
        expect(html).to include('&lt;script&gt;')
      end

      it 'is valid HTML' do
        expect(html).to include('<!DOCTYPE html>')
        expect(html).to include('</html>')
      end

      it 'includes error details' do
        expect(html).to include(error_message)
      end
    end
  end

  describe 'CallbackServer' do
    let(:tcp_server) { instance_double('TCPServer') }
    let(:thread) { instance_double('Thread') }
    let(:stop_callback) { -> {} }
    let(:callback_server) do
      described_class::CallbackServer.new(tcp_server, thread, stop_callback)
    end

    describe '#shutdown' do
      it 'calls stop callback' do
        expect(stop_callback).to receive(:call)
        allow(tcp_server).to receive(:close)
        allow(thread).to receive(:join)

        callback_server.shutdown
      end

      it 'closes TCP server' do
        allow(stop_callback).to receive(:call)
        expect(tcp_server).to receive(:close)
        allow(thread).to receive(:join)

        callback_server.shutdown
      end

      it 'waits for thread to finish' do
        allow(stop_callback).to receive(:call)
        allow(tcp_server).to receive(:close)
        expect(thread).to receive(:join).with(2)

        callback_server.shutdown
      end

      it 'handles nil callback gracefully' do
        server = described_class::CallbackServer.new(tcp_server, thread, nil)

        allow(tcp_server).to receive(:close)
        allow(thread).to receive(:join)

        expect { server.shutdown }.not_to raise_error
      end
    end
  end

  describe 'security features' do
    describe 'request validation' do
      let(:client) { instance_double('TCPSocket') }
      let(:result) { {} }
      let(:mutex) { Mutex.new }
      let(:condition) { ConditionVariable.new }

      before do
        allow(client).to receive(:setsockopt)
        allow(client).to receive(:print)
        allow(client).to receive(:close)
      end

      it 'rejects malformed HTTP requests' do
        allow(client).to receive(:gets).and_return('INVALID REQUEST', nil)

        browser_oauth.send(:handle_http_request, client, result, mutex, condition)

        # Should not process malformed request
        expect(result[:completed]).to be_falsy
      end

      it 'enforces header count limit' do
        # Create headers exceeding the 100 header limit
        headers = Array.new(101) { "Header: value\r\n" }
        allow(client).to receive(:gets).and_return(
          "GET /callback?code=123&state=abc HTTP/1.1\r\n",
          *headers,
          "\r\n",
          nil
        )

        # Should stop reading after 100 headers
        browser_oauth.send(:handle_http_request, client, result, mutex, condition)

        # Request should still complete (loop breaks at limit)
        mutex.synchronize do
          expect(result[:completed]).to be true
        end
      end

      it 'handles requests to non-callback paths' do
        allow(client).to receive(:gets).and_return(
          "GET /other-path HTTP/1.1\r\n",
          "\r\n",
          nil
        )

        expect(client).to receive(:print).with(/404/)

        browser_oauth.send(:handle_http_request, client, result, mutex, condition)

        # Should not complete OAuth flow for wrong path
        expect(result[:completed]).to be_falsy
      end
    end

    describe 'socket timeout' do
      let(:client) { instance_double('TCPSocket') }
      let(:result) { {} }
      let(:mutex) { Mutex.new }
      let(:condition) { ConditionVariable.new }

      it 'sets read timeout on client socket' do
        expect(client).to receive(:setsockopt).with(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [5, 0].pack('l_2'))
        allow(client).to receive(:gets).and_return(nil)
        allow(client).to receive(:print)
        allow(client).to receive(:close)

        browser_oauth.send(:handle_http_request, client, result, mutex, condition)
      end
    end
  end
end
