# frozen_string_literal: true

require 'zlib'
require 'stringio'

module MCPClient
  module JsonRpcCommon
    # Reading a JSON-RPC error object out of an HTTP error response body,
    # bounded in size and inflated only within that bound. Mixed into
    # {MCPClient::JsonRpcCommon}, so every transport that includes it has
    # these helpers.
    module ErrorBodies
      # Build the error for a 4xx response: the typed JSON-RPC error when the
      # body is a JSON-RPC error response (with the HTTP status prefixed to the
      # peer's message), otherwise a plain ServerError with the fallback text.
      # @param response [Faraday::Response] the 4xx response
      # @param fallback [String] message when the body carries no JSON-RPC error
      # @return [MCPClient::Errors::ServerError]
      def jsonrpc_error_from_http_response(response, fallback)
        status = response.status
        error = jsonrpc_error_in_body(response)
        return MCPClient::Errors::ServerError.new(fallback).tap { |e| e.http_status = status } unless error

        typed = MCPClient::Errors::ServerError.from_jsonrpc(error)
        typed.class.new("#{fallback}: #{typed.message}", code: typed.code, data: typed.data)
             .tap { |e| e.http_status = status }
      end

      # Ceiling on the size of an HTTP error body inspected for a JSON-RPC
      # error. A protocol error response is a few hundred bytes; the body is
      # peer-controlled, so anything larger is not parsed at all rather than
      # handed to JSON.parse.
      MAX_ERROR_BODY_BYTES = 64 * 1024

      # Extract a JSON-RPC error object from an HTTP error body, if there is one.
      # Only a JSON-RPC 2.0 error response is recognized; anything else is
      # ignored.
      # @param response [Faraday::Response] the HTTP response
      # @return [Hash, nil] the JSON-RPC `error` member, or nil
      def jsonrpc_error_in_body(response)
        return nil unless response.respond_to?(:body)

        data = decoded_error_body(response)
        # Only a JSON-RPC 2.0 error response counts; an arbitrary JSON body
        # with an "error" member is not a protocol error.
        return nil unless data.is_a?(Hash) && (data['jsonrpc'] || data[:jsonrpc]) == '2.0'

        error = data['error'] || data[:error]
        error.is_a?(Hash) ? error : nil
      end

      # The error body as a decoded object.
      #
      # A host may configure the connection (faraday_config) with response
      # middleware — `conn.response :json` — that decodes the body before it
      # reaches this transport, on the exception path (`raise_error`) as well
      # as the response path. That already-parsed body carries the same
      # protocol error, so it is accepted as-is; only a raw String body is
      # size-bounded, gunzipped and parsed here (the middleware has already
      # spent the memory for the ones it decoded).
      # @param response [Faraday::Response] the HTTP response
      # @return [Object, nil] the decoded body, or nil when it cannot be read
      def decoded_error_body(response)
        body = response.body
        return body if body.is_a?(Hash)
        return nil unless body.is_a?(String) && !body.empty?
        return nil if oversized_error_body?(body)

        headers = response.respond_to?(:headers) ? response.headers || {} : {}
        encoding = headers['content-encoding'] || headers['Content-Encoding'] || ''
        body = gunzip_bounded(body) if encoding.include?('gzip')
        return nil if body.nil?

        JSON.parse(body)
      rescue JSON::ParserError, Zlib::Error => e
        @logger.debug("HTTP error body is not a JSON-RPC error: #{e.class}")
        nil
      end

      # @param body [String] an HTTP error body
      # @return [Boolean] whether it exceeds the inspection ceiling (logged)
      def oversized_error_body?(body)
        return false if body.bytesize <= MAX_ERROR_BODY_BYTES

        @logger.debug("Ignoring HTTP error body of #{body.bytesize} bytes (over #{MAX_ERROR_BODY_BYTES})")
        true
      end

      # Decompress a gzip error body, giving up once the expansion passes the
      # inspection ceiling (a compressed 4xx body is peer-controlled too).
      # @param body [String] gzip data
      # @return [String, nil] the decompressed body, or nil when too large
      def gunzip_bounded(body)
        reader = Zlib::GzipReader.new(StringIO.new(body))
        expanded = reader.read(MAX_ERROR_BODY_BYTES + 1) || ''
        return expanded if expanded.bytesize <= MAX_ERROR_BODY_BYTES

        @logger.debug("Ignoring gzip HTTP error body expanding past #{MAX_ERROR_BODY_BYTES} bytes")
        nil
      ensure
        reader&.close
      end
    end
  end
end
