# frozen_string_literal: true

require 'spec_helper'
require 'openssl'

RSpec.describe 'Faraday Configuration' do
  describe 'MCPClient.http_config' do
    it 'stores faraday_config block as Proc' do
      config = MCPClient.http_config(base_url: 'https://example.com') do |faraday|
        faraday.ssl.verify = false
      end

      expect(config[:faraday_config]).to be_a(Proc)
    end

    it 'stores nil faraday_config when no block given' do
      config = MCPClient.http_config(base_url: 'https://example.com')

      expect(config[:faraday_config]).to be_nil
    end
  end

  describe 'MCPClient.streamable_http_config' do
    it 'stores faraday_config block as Proc' do
      config = MCPClient.streamable_http_config(base_url: 'https://example.com') do |faraday|
        faraday.ssl.verify = false
      end

      expect(config[:faraday_config]).to be_a(Proc)
    end

    it 'stores nil faraday_config when no block given' do
      config = MCPClient.streamable_http_config(base_url: 'https://example.com')

      expect(config[:faraday_config]).to be_nil
    end
  end

  describe 'MCPClient::HttpTransportBase#create_http_connection' do
    let(:test_class) do
      Class.new do
        include MCPClient::HttpTransportBase

        attr_accessor :faraday_config, :base_url, :max_retries, :retry_backoff, :read_timeout, :logger, :mutex, :headers

        def initialize(faraday_config: nil)
          @faraday_config = faraday_config
          @base_url = 'https://example.com'
          @max_retries = 3
          @retry_backoff = 1
          @read_timeout = 30
          @logger = Logger.new(nil)
          @mutex = Monitor.new
          @headers = {}
          @request_id = 0
        end

        # Expose private method for testing
        def test_create_http_connection
          create_http_connection
        end

        # Stub abstract methods
        def parse_response(_response)
          {}
        end

        def ensure_connected; end
      end
    end

    it 'creates Faraday connection without calling block when nil' do
      transport = test_class.new

      conn = transport.test_create_http_connection

      expect(conn).to be_a(Faraday::Connection)
    end

    it 'calls faraday_config block with the connection' do
      block_called = false
      connection_received = nil

      transport = test_class.new(faraday_config: proc do |conn|
        block_called = true
        connection_received = conn
      end)

      result = transport.test_create_http_connection

      expect(block_called).to be true
      expect(connection_received).to be_a(Faraday::Connection)
      expect(result).to eq(connection_received)
    end

    it 'allows user to customize SSL settings via block' do
      cert_store = OpenSSL::X509::Store.new

      transport = test_class.new(faraday_config: proc do |conn|
        conn.ssl.cert_store = cert_store
        conn.ssl.verify = true
      end)

      conn = transport.test_create_http_connection

      expect(conn.ssl.cert_store).to eq(cert_store)
      expect(conn.ssl.verify).to be true
    end

    it 'allows user to add middleware via block' do
      transport = test_class.new(faraday_config: proc do |conn|
        conn.response :logger
      end)

      conn = transport.test_create_http_connection

      expect(conn.builder.handlers.map(&:name)).to include('Faraday::Response::Logger')
    end
  end

  describe 'MCPClient::ServerHTTP' do
    it 'stores faraday_config from initialization' do
      config_block = proc { |f| f.ssl.verify = false }

      server = MCPClient::ServerHTTP.new(
        base_url: 'https://example.com',
        faraday_config: config_block
      )

      expect(server.instance_variable_get(:@faraday_config)).to eq(config_block)
    end

    it 'defaults faraday_config to nil' do
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com')

      expect(server.instance_variable_get(:@faraday_config)).to be_nil
    end
  end

  describe 'MCPClient::ServerStreamableHTTP' do
    it 'stores faraday_config from initialization' do
      config_block = proc { |f| f.ssl.verify = false }

      server = MCPClient::ServerStreamableHTTP.new(
        base_url: 'https://example.com',
        faraday_config: config_block
      )

      expect(server.instance_variable_get(:@faraday_config)).to eq(config_block)
    end

    it 'defaults faraday_config to nil' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com')

      expect(server.instance_variable_get(:@faraday_config)).to be_nil
    end
  end

  describe 'MCPClient::ServerFactory' do
    it 'passes faraday_config to ServerHTTP' do
      config_block = proc { |f| f.ssl.verify = false }
      config = { type: 'http', base_url: 'https://example.com', faraday_config: config_block }

      server = MCPClient::ServerFactory.create(config)

      expect(server.instance_variable_get(:@faraday_config)).to eq(config_block)
    end

    it 'passes faraday_config to ServerStreamableHTTP' do
      config_block = proc { |f| f.ssl.verify = false }
      config = { type: 'streamable_http', base_url: 'https://example.com', faraday_config: config_block }

      server = MCPClient::ServerFactory.create(config)

      expect(server.instance_variable_get(:@faraday_config)).to eq(config_block)
    end
  end
end
