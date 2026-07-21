# frozen_string_literal: true

require_relative '../http_transport_base'

require 'zlib'
require 'stringio'

module MCPClient
  class ServerStreamableHTTP
    # JSON-RPC request/notification plumbing for Streamable HTTP transport
    # This transport uses HTTP POST requests but expects Server-Sent Event formatted responses
    module JsonRpcTransport
      include HttpTransportBase

      private

      # Log HTTP response for Streamable HTTP
      # @param response [Faraday::Response] the HTTP response
      def log_response(response)
        @logger.debug("Received Streamable HTTP response: #{response.status} #{response.body}")
      end

      # Parse a Streamable HTTP JSON-RPC response (JSON or SSE format)
      # @param response [Faraday::Response] the HTTP response
      # @param request [Hash, nil] the originating JSON-RPC request, used to match the response by id
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      def parse_response(response, request = nil)
        body = response.body
        content_type = response.headers['content-type'] || response.headers['Content-Type'] || ''
        content_encoding = response.headers['content-encoding'] || response.headers['Content-Encoding'] || ''

        body = Zlib::GzipReader.new(StringIO.new(body)).read if content_encoding.include?('gzip')
        body = body&.strip

        # Determine response format based on Content-Type header per MCP 2025 spec
        data = if content_type.include?('text/event-stream')
                 # Parse SSE-formatted response for streaming
                 parse_sse_response(body, request && request['id'])
               else
                 # Parse regular JSON response (default for Streamable HTTP)
                 JSON.parse(body)
               end

        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      end

      # Parse a Server-Sent Event formatted response body.
      #
      # Per MCP 2025-11-25, the server MAY send JSON-RPC requests and
      # notifications on the POST response stream before the response, and MAY
      # send priming events carrying only an event id. Every interleaved server
      # message is dispatched exactly like on the GET events stream; the
      # JSON-RPC response matching the originating request id is returned.
      #
      # @param sse_body [String] the SSE formatted response body
      # @param request_id [Integer, String, nil] id of the originating request
      # @return [Hash] the parsed JSON-RPC response
      # @raise [MCPClient::Errors::TransportError] if no response is found
      def parse_sse_response(sse_body, request_id = nil)
        events, retry_ms = extract_sse_events(sse_body)

        raise MCPClient::Errors::TransportError, 'No data found in SSE response' if events.empty?

        responses, saw_invalid_json = route_sse_events(events)
        matched = select_sse_response(responses, request_id)
        return matched if matched

        if saw_invalid_json
          raise MCPClient::Errors::TransportError,
                'Invalid JSON response from server: SSE stream contained no valid JSON-RPC response'
        end

        resume_or_fail(events, request_id, retry_ms)
      end

      # SEP-1699 polling pattern: the server MAY close the POST stream before
      # delivering the response. When a cursor was received, resume via HTTP
      # GET with Last-Event-ID instead of re-POSTing the (possibly
      # non-idempotent) request.
      # @param events [Array<Hash>] parsed SSE events
      # @param request_id [Integer, String, nil] id of the originating request
      # @param retry_ms [Integer, nil] retry directive received on THIS stream
      # @return [Hash] the replayed JSON-RPC response
      # @raise [MCPClient::Errors::ServerError] when resumption fails
      # @raise [MCPClient::Errors::TransportError] when no cursor was received
      def resume_or_fail(events, request_id, retry_ms = nil)
        cursor = events.reverse.find { |e| e[:id] && !e[:id].empty? }&.dig(:id)
        if request_id && cursor
          # Resume with THIS stream's cursor and retry directive (both are
          # per-stream), not the shared @last_event_id / @sse_retry_ms which a
          # concurrent stream may have moved between parsing and resumption.
          resumed = resume_response_via_get(request_id, cursor, retry_ms)
          return resumed if resumed

          # Non-retryable: the request may already be executing server-side,
          # so a blind re-POST could run a non-idempotent operation twice.
          raise MCPClient::Errors::ServerError,
                'SSE stream closed before delivering the response and resumption via GET failed'
        end

        raise MCPClient::Errors::TransportError, 'No JSON-RPC response found in SSE response'
      end

      # Split an SSE body into events. An event without an explicit `event:`
      # field has the default type "message" per the SSE specification; events
      # carrying only an id (priming events) are kept so their id is tracked.
      # @param sse_body [String] the SSE formatted response body
      # @return [Array(Array<Hash>, Integer, nil)] parsed events and the last
      #   retry directive (ms) received on this stream, if any
      def extract_sse_events(sse_body)
        events = []
        retry_ms = nil
        current_event = { type: 'message', data_lines: [], id: nil }

        sse_body.lines.each do |line|
          line = line.strip

          if line.empty?
            # Empty line marks end of an event
            events << current_event.dup if sse_event_present?(current_event)
            current_event = { type: 'message', data_lines: [], id: nil }
          elsif line.start_with?('event:')
            current_event[:type] = line.sub(/^event:\s*/, '').strip
          elsif line.start_with?('data:')
            current_event[:data_lines] << line.sub(/^data:\s*/, '').strip
          elsif line.start_with?('id:')
            current_event[:id] = line.sub(/^id:\s*/, '').strip
          elsif line.start_with?('retry:')
            # SEP-1699: the client MUST respect the server's retry directive.
            # Track it locally for this stream's resumption; the shared ivar is
            # only a hint for the general events loop.
            raw = line.sub(/^retry:\s*/, '').strip
            if raw.match?(/\A\d+\z/)
              retry_ms = raw.to_i
              @sse_retry_ms = retry_ms
            end
          end
        end

        # Handle last event if no trailing empty line
        events << current_event if sse_event_present?(current_event)
        [events, retry_ms]
      end

      # @param event [Hash] a parsed SSE event
      # @return [Boolean] whether the event carries any data or id
      def sse_event_present?(event)
        (event[:id] && !event[:id].empty?) || !event[:data_lines].empty?
      end

      # Track event ids for resumability, dispatch interleaved server messages
      # (requests, notifications, pings) and collect response candidates.
      # @param events [Array<Hash>] parsed SSE events
      # @return [Array(Array<Hash>, Boolean)] response candidates and whether invalid JSON was seen
      def route_sse_events(events)
        responses = []
        saw_invalid_json = false

        events.each do |event|
          if event[:id] && !event[:id].empty?
            @mutex.synchronize { @last_event_id = event[:id] }
            @logger.debug("Tracking event ID for resumability: #{event[:id]}")
          end
          next unless event[:type] == 'message'

          message = parse_sse_event_data(event[:data_lines].join("\n"))
          saw_invalid_json = true if message == :invalid
          next unless message.is_a?(Hash)

          if message['method']
            dispatch_server_message(message)
          else
            responses << message
          end
        end

        [responses, saw_invalid_json]
      end

      # Parse the data payload of a single SSE event.
      # @param json_data [String] the joined data lines
      # @return [Hash, Symbol, nil] the parsed message, :invalid, or nil for empty/non-object data
      def parse_sse_event_data(json_data)
        return nil if json_data.empty?

        message = JSON.parse(json_data)
        return message if message.is_a?(Hash)

        @logger.warn("Skipping non-object JSON-RPC message in SSE event: #{message.inspect}")
        nil
      rescue JSON::ParserError => e
        @logger.warn("Skipping invalid JSON in SSE event: #{e.message}")
        :invalid
      end

      # Choose the JSON-RPC response answering the originating request.
      # @param responses [Array<Hash>] response candidates from the stream
      # @param request_id [Integer, String, nil] id of the originating request
      # @return [Hash, nil] the selected response, if any
      def select_sse_response(responses, request_id)
        matched = if request_id.nil?
                    responses.first
                  else
                    responses.find { |msg| msg['id'] == request_id || msg['id'].to_s == request_id.to_s }
                  end

        if matched.nil? && responses.length == 1
          matched = responses.first
          @logger.warn(
            "SSE response id #{matched['id'].inspect} does not match request id #{request_id.inspect}; " \
            'accepting the only response on the stream'
          )
        end

        matched
      end
    end
  end
end
