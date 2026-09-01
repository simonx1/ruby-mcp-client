# frozen_string_literal: true

require_relative '../json_rpc_common'

module MCPClient
  class ServerStdio
    # JSON-RPC request/notification plumbing for stdio transport
    module JsonRpcTransport
      include JsonRpcCommon

      # Ensure the server process is started and initialized (handshake)
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def ensure_initialized
        return if @initialized

        connect
        start_reader
        start_stderr_reader
        negotiate_protocol

        @initialized = true
      end

      # Establish the server's protocol era (MCP 2026-07-28
      # basic/transports/stdio "Backward Compatibility"): probe with
      # server/discover unless configured legacy-only, and fall back to the
      # initialize handshake when the probe shows a legacy server.
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if no era can be established
      def negotiate_protocol
        return perform_initialize if @protocol_mode == :legacy
        return if probe_modern_server

        perform_initialize
      end

      # Send the server/discover probe with this client's preferred modern
      # version. Three outcomes, per the stdio backward-compatibility rules:
      # a DiscoverResult (modern: select a version from supportedVersions), a
      # recognized modern error such as UnsupportedProtocolVersionError
      # (modern: retry with an advertised version, never fall back), or any
      # other error / a timeout (legacy: fall back to initialize). The
      # fallback is deliberately not keyed to one error code — legacy servers
      # answer pre-initialize requests with implementation-defined errors.
      # @return [Boolean] true when the server is modern and a version was selected
      # @raise [MCPClient::Errors::ConnectionError] if the server is modern but no
      #   version is mutually supported, or legacy while protocol: :modern is configured
      def probe_modern_server
        @protocol_version = MCPClient::LATEST_PROTOCOL_VERSION
        begin
          perform_discover
        rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
          retry_discover_with_advertised_version(e)
        end
        true
      rescue MCPClient::Errors::UnsupportedProtocolVersionError, MCPClient::Errors::InvalidResultError => e
        @protocol_version = nil
        raise MCPClient::Errors::ConnectionError, "Server is modern but incompatible: #{e.message}"
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError => e
        # Not a recognized modern error: a legacy server (or one that never
        # answered). Its message is peer-controlled but already
        # passes through ServerError elsewhere.
        @protocol_version = nil
        if @protocol_mode == :modern
          raise MCPClient::Errors::ConnectionError,
                "Server did not answer server/discover as a modern MCP server (#{e.message}); it is most likely " \
                'a legacy server expecting the initialize handshake. Use protocol: :auto or :legacy to allow that.'
        end

        @logger.debug("server/discover probe failed (#{e.class}); treating the server as legacy")
        false
      end

      # After UnsupportedProtocolVersionError, pick a mutually supported
      # version from the error's advertised list and re-issue the probe.
      # @param error [MCPClient::Errors::UnsupportedProtocolVersionError]
      # @return [void]
      def retry_discover_with_advertised_version(error)
        version = select_protocol_version(error.supported)
        unless version
          raise MCPClient::Errors::ConnectionError,
                "Server rejected protocol version #{@protocol_version} and supports only " \
                "#{error.supported.join(', ')}, none of which this client speaks"
        end

        @logger.info("Server does not support #{@protocol_version}; retrying server/discover with #{version}")
        @protocol_version = version
        perform_discover
      end

      # Send server/discover and apply the DiscoverResult. Bounded by
      # discover_timeout rather than the general read timeout so a silent
      # legacy server delays the fallback only briefly.
      # @return [Hash] the DiscoverResult
      def perform_discover
        req_id = next_id
        req = build_jsonrpc_request('server/discover', {}, req_id)
        send_request(req)
        begin
          res = wait_response(req_id, timeout: @discover_timeout)
        rescue MCPClient::Errors::RequestTimeoutError
          send_cancellation_notification(req_id)
          raise
        end
        apply_discover_result(process_jsonrpc_response(res))
      end

      # Handshake: send initialize request and initialized notification
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def perform_initialize
        # Initialize request
        init_id = next_id
        init_req = build_jsonrpc_request('initialize', initialization_params, init_id)
        send_request(init_req)
        res = wait_response(init_id)
        begin
          result = process_jsonrpc_response(res) || {}
        rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
          # A modern-only server SHOULD name the versions it supports when
          # rejecting initialize (basic/versioning): surface them, since a
          # legacy-only configuration has no fall-forward path.
          raise MCPClient::Errors::ConnectionError,
                "Initialize failed: #{e.message} (server supports: #{e.supported.join(', ')})"
        rescue MCPClient::Errors::ServerError => e
          raise MCPClient::Errors::ConnectionError, "Initialize failed: #{e.message}"
        end

        # Store negotiated protocol version, server info and capabilities.
        # Disconnects if the server negotiated a version we cannot speak.
        @protocol_version = validate_protocol_version!(result)
        @server_info = result['serverInfo']
        @capabilities = result['capabilities']
        @instructions = result['instructions']

        # Send initialized notification
        notif = build_jsonrpc_notification('notifications/initialized', {})
        @stdin.puts(notif.to_json)
      end

      # Generate a new unique request ID and mark it as awaiting a response.
      # Registering the id before the request is sent lets the reader thread
      # distinguish expected responses from late/unsolicited ones.
      # @return [Integer] a unique request ID
      def next_id
        @mutex.synchronize do
          id = @next_id
          @next_id += 1
          @awaiting[id] = true
          id
        end
      end

      # Send a JSON-RPC request and return nothing
      # @param req [Hash] the JSON-RPC request
      # @return [void]
      # @raise [MCPClient::Errors::TransportError] on write errors
      def send_request(req)
        @logger.debug("Sending JSONRPC request: #{describe_jsonrpc_message(req)}")
        @stdin.puts(req.to_json)
      rescue StandardError => e
        # A request that failed to send will never receive a response, so drop
        # its awaiting marker; otherwise a broken transport (e.g. the server
        # exited) would leak an entry per retry/attempt into @awaiting.
        @mutex.synchronize { @awaiting.delete(req['id']) } if req.is_a?(Hash) && req['id']
        raise MCPClient::Errors::TransportError, "Failed to send JSONRPC request: #{e.message}"
      end

      # Wait for a response with the given request ID
      # @param id [Integer] the request ID
      # @return [Hash] the JSON-RPC response message
      # @raise [MCPClient::Errors::TransportError] on timeout
      def wait_response(id, timeout: nil)
        deadline = Time.now + (timeout || @read_timeout)
        @mutex.synchronize do
          until @pending.key?(id)
            remaining = deadline - Time.now
            break if remaining <= 0

            @cond.wait(@mutex, remaining)
          end
          # Remove the response and the awaiting marker on both success and
          # timeout so neither @pending nor @awaiting accumulates entries.
          msg = @pending.delete(id)
          @awaiting.delete(id)
          raise MCPClient::Errors::RequestTimeoutError, "Timeout waiting for JSONRPC response id=#{id}" unless msg

          msg
        end
      end

      # Stream tool call fallback for stdio transport (yields single result)
      # @param tool_name [String] the name of the tool to call
      # @param parameters [Hash] the parameters to pass to the tool
      # @return [Enumerator] a stream containing a single result
      def call_tool_streaming(tool_name, parameters)
        Enumerator.new do |yielder|
          yielder << call_tool(tool_name, parameters)
        end
      end

      # Generic JSON-RPC request: send method with params and wait for result
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the request
      # @return [Object] result from JSON-RPC response
      # @raise [MCPClient::Errors::ServerError] if server returns an error
      # @raise [MCPClient::Errors::TransportError] on transport errors
      # @raise [MCPClient::Errors::ToolCallError] on tool call errors
      def rpc_request(method, params = {}, timeout: nil)
        freshly_probed = !@initialized
        ensure_initialized
        if method == 'ping' && modern?
          # `ping` was removed in MCP 2026-07-28; the mandatory server/discover
          # request is the modern heartbeat. The probe that just established
          # the connection IS such a round trip, so answer from it rather than
          # paying for a second one.
          return @last_discover_result if freshly_probed && @last_discover_result

          method = 'server/discover'
        end

        with_retry(method) do
          send_request_and_wait(method, params, timeout)
        rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
          # MCP 2026-07-28 basic/versioning: "The client SHOULD select a
          # mutually supported version from the supported list and retry
          # the request". The server rejected the request before processing
          # it, so re-sending cannot duplicate a side effect.
          version = select_protocol_version(e.supported)
          raise unless modern? && version && version != protocol_version

          @logger.info("Server does not support protocol version #{protocol_version}; " \
                       "retrying #{method} with #{version}")
          @protocol_version = version
          send_request_and_wait(method, params, timeout)
        end
      end

      # One request/response exchange with its own JSON-RPC id.
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the request
      # @param timeout [Numeric, nil] per-request timeout override
      # @return [Object] result from the JSON-RPC response
      def send_request_and_wait(method, params, timeout)
        req_id = next_id
        req = build_jsonrpc_request(method, params, req_id)
        send_request(req)
        begin
          res = wait_response(req_id, timeout: timeout)
        rescue MCPClient::Errors::RequestTimeoutError
          # MCP lifecycle: on timeout the sender SHOULD issue a cancellation
          # notification for the abandoned request and stop waiting.
          send_cancellation_notification(req_id) if cancellable_request?(method, params)
          raise
        end
        process_jsonrpc_response(res)
      end

      # Best-effort notifications/cancelled for a request the client stopped
      # waiting on. Failures are swallowed: the transport may be the reason
      # the request timed out in the first place.
      # @param request_id [Integer] id of the abandoned request
      # @return [void]
      def send_cancellation_notification(request_id)
        notif = build_jsonrpc_notification('notifications/cancelled',
                                           { 'requestId' => request_id, 'reason' => 'Request timed out' })
        @stdin.puts(notif.to_json)
      rescue StandardError => e
        @logger.debug("Failed to send cancellation notification: #{e.message}")
      end

      # Send a JSON-RPC notification (no response expected)
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the notification
      # @return [void]
      def rpc_notify(method, params = {})
        ensure_initialized
        notif = build_jsonrpc_notification(method, params)
        @stdin.puts(notif.to_json)
      end
    end
  end
end
