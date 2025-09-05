# frozen_string_literal: true

require 'spec_helper'
require 'mcp_client/server_sse/sse_parser'

RSpec.describe MCPClient::ServerSSE::SseParser do
  let(:dummy_class) do
    Class.new do
      include MCPClient::ServerSSE::SseParser

      attr_reader :rpc_endpoint, :sse_connected, :connection_established, :notification_calls

      def initialize
        @mutex = Mutex.new
        cv = Object.new
        def cv.broadcast; end
        @connection_cv = cv
        @logger = Logger.new(StringIO.new)
        @notification_callback = proc { |m, p|
          @notification_calls ||= []
          @notification_calls << [m, p]
        }
        @sse_results = {}
        @tools_data = nil
        @prompts_data = nil
      end

      def record_activity; end

      def authorization_error?(_msg, _code) = false

      def handle_sse_auth_error_message(_msg); end
    end
  end

  subject(:parser) { dummy_class.new }

  describe '#parse_sse_event' do
    it 'parses event type, data, and id' do
      raw = "event: test_event\ndata: line1\ndata: line2\nid: 42\n\n"
      expect(parser.parse_sse_event(raw)).to eq(event: 'test_event', data: "line1\nline2", id: '42')
    end

    it 'returns nil for comment-only events' do
      expect(parser.parse_sse_event(": comment\n\n")).to be_nil
    end

    it 'defaults to message event for data-only lines' do
      raw = "data: hello\n\n"
      expect(parser.parse_sse_event(raw)[:event]).to eq('message')
      expect(parser.parse_sse_event(raw)[:data]).to eq('hello')
    end
  end

  describe '#parse_and_handle_sse_event' do
    it 'handles endpoint events by setting rpc_endpoint and connection flags' do
      raw = "event: endpoint\ndata: /foo\n\n"
      parser.parse_and_handle_sse_event(raw)
      expect(parser.rpc_endpoint).to eq('/foo')
      expect(parser.sse_connected).to be true
      expect(parser.connection_established).to be true
    end

    it 'ignores ping events' do
      expect { parser.parse_and_handle_sse_event("event: ping\n\n") }.not_to raise_error
    end

    it 'calls notification callback for JSON-RPC notifications' do
      notification = { method: 'n', params: { 'a' => 1 } }
      raw = "event: message\ndata: #{notification.to_json}\n\n"
      parser.parse_and_handle_sse_event(raw)
      expect(parser.notification_calls).to eq([['n', { 'a' => 1 }]])
    end
  end
end
