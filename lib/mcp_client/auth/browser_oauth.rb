# frozen_string_literal: true

require 'socket'
require 'uri'
require 'cgi'
require_relative 'oauth_provider'

module MCPClient
  module Auth
    # Browser-based OAuth authentication flow helper
    # Provides a complete OAuth flow using browser authentication with a local callback server
    class BrowserOAuth
      # @!attribute [r] oauth_provider
      #   @return [OAuthProvider] The OAuth provider instance
      # @!attribute [r] callback_port
      #   @return [Integer] Port for local callback server
      # @!attribute [r] callback_path
      #   @return [String] Path for OAuth callback
      # @!attribute [r] logger
      #   @return [Logger] Logger instance
      attr_reader :oauth_provider, :callback_port, :callback_path, :logger

      # Initialize browser OAuth helper
      # @param oauth_provider [OAuthProvider] OAuth provider to use for authentication
      # @param callback_port [Integer] Port for local callback server (default: 8080)
      # @param callback_path [String] Path for OAuth callback (default: '/callback')
      # @param logger [Logger, nil] Optional logger
      def initialize(oauth_provider, callback_port: 8080, callback_path: '/callback', logger: nil)
        @oauth_provider = oauth_provider
        @callback_port = callback_port
        @callback_path = callback_path
        @logger = logger || Logger.new($stdout, level: Logger::WARN)

        # Ensure OAuth provider's redirect_uri matches our callback server
        expected_redirect_uri = "http://localhost:#{callback_port}#{callback_path}"
        return unless oauth_provider.redirect_uri != expected_redirect_uri

        @logger.warn("OAuth provider redirect_uri (#{oauth_provider.redirect_uri}) doesn't match " \
                     "callback server (#{expected_redirect_uri}). Updating redirect_uri.")
        oauth_provider.redirect_uri = expected_redirect_uri
      end

      # Perform complete browser-based OAuth authentication flow
      # This will:
      # 1. Start a local HTTP server to handle the callback
      # 2. Open the authorization URL in the user's browser
      # 3. Wait for the user to authorize and receive the callback
      # 4. Complete the OAuth flow and return the token
      # @param timeout [Integer] Timeout in seconds to wait for callback (default: 300 = 5 minutes)
      # @param auto_open_browser [Boolean] Automatically open browser (default: true)
      # @return [Token] Access token after successful authentication
      # @raise [Timeout::Error] if user doesn't complete auth within timeout
      # @raise [MCPClient::Errors::ConnectionError] if OAuth flow fails
      def authenticate(timeout: 300, auto_open_browser: true)
        # Start authorization flow and get URL
        auth_url = @oauth_provider.start_authorization_flow
        @logger.debug("Authorization URL: #{auth_url}")

        # Create a result container to share data between threads
        result = { code: nil, state: nil, error: nil, completed: false }
        mutex = Mutex.new
        condition = ConditionVariable.new

        # Start local callback server
        server = start_callback_server(result, mutex, condition)

        begin
          # Open browser to authorization URL
          if auto_open_browser
            open_browser(auth_url)
            @logger.info("\nOpening browser for authorization...")
            @logger.info("If browser doesn't open automatically, visit this URL:")
          else
            @logger.info("\nPlease visit this URL to authorize:")
          end
          @logger.info(auth_url)
          @logger.info("\nWaiting for authorization...")

          # Wait for callback with timeout
          mutex.synchronize do
            condition.wait(mutex, timeout) unless result[:completed]
          end

          # Check if we got a response
          raise Timeout::Error, "OAuth authorization timed out after #{timeout} seconds" unless result[:completed]

          # Check for errors
          raise MCPClient::Errors::ConnectionError, "OAuth authorization failed: #{result[:error]}" if result[:error]

          # Complete OAuth flow
          @logger.debug('Completing OAuth authorization flow')
          token = @oauth_provider.complete_authorization_flow(result[:code], result[:state])

          @logger.info("\nAuthentication successful!")
          token
        ensure
          # Always shutdown the server
          server&.shutdown
        end
      end

      # Start the local callback server using TCPServer
      # @param result [Hash] Hash to store callback results
      # @param mutex [Mutex] Mutex for thread synchronization
      # @param condition [ConditionVariable] Condition variable for thread signaling
      # @return [CallbackServer] The running callback server
      # @raise [MCPClient::Errors::ConnectionError] if port is already in use
      # @private
      def start_callback_server(result, mutex, condition)
        begin
          server = TCPServer.new('127.0.0.1', @callback_port)
          @logger.debug("Started callback server on http://127.0.0.1:#{@callback_port}#{@callback_path}")
        rescue Errno::EADDRINUSE
          raise MCPClient::Errors::ConnectionError,
                "Cannot start OAuth callback server: port #{@callback_port} is already in use. " \
                'Please close the application using this port or choose a different callback_port.'
        rescue StandardError => e
          raise MCPClient::Errors::ConnectionError,
                "Failed to start OAuth callback server on port #{@callback_port}: #{e.message}"
        end

        running = true

        # Start server in background thread
        thread = Thread.new do
          while running
            begin
              # Use wait_readable with timeout to allow checking the running flag
              next unless server.wait_readable(0.5)

              client = server.accept
              handle_http_request(client, result, mutex, condition)
            rescue IOError, Errno::EBADF
              # Server was closed, exit loop
              break
            rescue StandardError => e
              @logger.error("Error handling callback request: #{e.message}")
            end
          end
        end

        # Return an object with shutdown method for compatibility
        CallbackServer.new(server, thread, -> { running = false })
      end

      # Handle HTTP request from OAuth callback
      # @param client [TCPSocket] The client socket
      # @param result [Hash] Hash to store callback results
      # @param mutex [Mutex] Mutex for thread synchronization
      # @param condition [ConditionVariable] Condition variable for thread signaling
      # @private
      def handle_http_request(client, result, mutex, condition)
        # Set read timeout to prevent hanging connections
        client.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [5, 0].pack('l_2'))

        # Read request line
        request_line = client.gets
        return unless request_line

        parts = request_line.split
        return unless parts.length >= 2

        method, path = parts[0..1]
        @logger.debug("Received #{method} request: #{path}")

        # Read and discard headers until blank line (with limit to prevent memory exhaustion)
        header_count = 0
        loop do
          break if header_count >= 100 # Limit header count

          line = client.gets
          break if line.nil? || line.strip.empty?

          header_count += 1
        end

        # Parse path and query parameters
        uri_path, query_string = path.split('?', 2)

        # Only handle our callback path
        unless uri_path == @callback_path
          send_http_response(client, 404, 'text/plain', 'Not Found')
          return
        end

        # Parse query parameters
        params = parse_query_params(query_string || '')
        @logger.debug("Callback params: #{params.keys.join(', ')}")

        # Extract OAuth parameters
        code = params['code']
        state = params['state']
        error = params['error']
        error_description = params['error_description']

        # Update result and signal waiting thread
        mutex.synchronize do
          if error
            result[:error] = error_description || error
          elsif code && state
            result[:code] = code
            result[:state] = state
          else
            result[:error] = 'Invalid callback: missing code or state parameter'
          end
          result[:completed] = true

          condition.signal
        end

        # Send HTML response to browser
        if result[:error]
          send_http_response(client, 400, 'text/html', error_page(result[:error]))
        else
          send_http_response(client, 200, 'text/html', success_page)
        end
      ensure
        client&.close
      end

      # Parse URL query parameters
      # @param query_string [String] Query string from URL
      # @return [Hash] Parsed parameters
      # @private
      def parse_query_params(query_string)
        params = {}
        query_string.split('&').each do |param|
          next if param.empty?

          key, value = param.split('=', 2)
          params[CGI.unescape(key)] = CGI.unescape(value || '')
        end
        params
      end

      # Send HTTP response to client
      # @param client [TCPSocket] The client socket
      # @param status_code [Integer] HTTP status code
      # @param content_type [String] Content type header value
      # @param body [String] Response body
      # @private
      def send_http_response(client, status_code, content_type, body)
        status_text = case status_code
                      when 200 then 'OK'
                      when 400 then 'Bad Request'
                      when 404 then 'Not Found'
                      else 'Unknown'
                      end

        response = "HTTP/1.1 #{status_code} #{status_text}\r\n"
        response += "Content-Type: #{content_type}; charset=utf-8\r\n"
        response += "Content-Length: #{body.bytesize}\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        response += body

        client.print(response)
      end

      # Open URL in default browser
      # @param url [String] URL to open
      # @return [Boolean] true if browser opened successfully
      def open_browser(url)
        case RbConfig::CONFIG['host_os']
        when /darwin/
          system('open', url)
        when /linux|bsd/
          system('xdg-open', url)
        when /mswin|mingw|cygwin/
          system('start', url)
        else
          @logger.warn('Unknown operating system, cannot open browser automatically')
          false
        end
      rescue StandardError => e
        @logger.warn("Failed to open browser: #{e.message}")
        false
      end

      private

      # HTML page shown on successful authentication
      # @return [String] HTML content
      def success_page
        <<~HTML
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8">
            <title>Authentication Successful</title>
            <style>
              body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                display: flex;
                justify-content: center;
                align-items: center;
                height: 100vh;
                margin: 0;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
              }
              .container {
                background: white;
                padding: 3rem;
                border-radius: 1rem;
                box-shadow: 0 20px 60px rgba(0,0,0,0.3);
                text-align: center;
                max-width: 400px;
              }
              .icon {
                font-size: 4rem;
                margin-bottom: 1rem;
              }
              h1 {
                color: #333;
                margin: 0 0 1rem 0;
                font-size: 1.5rem;
              }
              p {
                color: #666;
                margin: 0;
                line-height: 1.5;
              }
            </style>
          </head>
          <body>
            <div class="container">
              <div class="icon">✅</div>
              <h1>Authentication Successful!</h1>
              <p>You have successfully authenticated. You can close this window and return to your application.</p>
            </div>
          </body>
          </html>
        HTML
      end

      # HTML page shown on authentication error
      # @param error_message [String] Error message to display
      # @return [String] HTML content
      def error_page(error_message)
        <<~HTML
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8">
            <title>Authentication Failed</title>
            <style>
              body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                display: flex;
                justify-content: center;
                align-items: center;
                height: 100vh;
                margin: 0;
                background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
              }
              .container {
                background: white;
                padding: 3rem;
                border-radius: 1rem;
                box-shadow: 0 20px 60px rgba(0,0,0,0.3);
                text-align: center;
                max-width: 400px;
              }
              .icon {
                font-size: 4rem;
                margin-bottom: 1rem;
              }
              h1 {
                color: #333;
                margin: 0 0 1rem 0;
                font-size: 1.5rem;
              }
              p {
                color: #666;
                margin: 0;
                line-height: 1.5;
              }
              .error {
                background: #fee;
                border: 1px solid #fcc;
                border-radius: 0.5rem;
                padding: 1rem;
                margin-top: 1rem;
                color: #c33;
                font-family: monospace;
                font-size: 0.875rem;
              }
            </style>
          </head>
          <body>
            <div class="container">
              <div class="icon">❌</div>
              <h1>Authentication Failed</h1>
              <p>An error occurred during authentication.</p>
              <div class="error">#{CGI.escapeHTML(error_message)}</div>
            </div>
          </body>
          </html>
        HTML
      end

      # Wrapper class for TCPServer to provide shutdown interface
      # @private
      class CallbackServer
        def initialize(tcp_server, thread, stop_callback)
          @tcp_server = tcp_server
          @thread = thread
          @stop_callback = stop_callback
        end

        def shutdown
          # Signal the thread to stop
          @stop_callback&.call

          # Close the server socket
          @tcp_server&.close

          # Wait for thread to finish (with timeout)
          @thread&.join(2)
        end
      end
    end
  end
end
