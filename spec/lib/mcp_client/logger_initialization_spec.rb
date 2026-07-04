# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Logger Initialization' do
  let(:custom_logger) { Logger.new($stdout) }
  let(:custom_formatter) do
    proc do |severity, datetime, progname, msg|
      "CUSTOM-FORMAT: #{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{progname}: #{msg}\n"
    end
  end

  before do
    custom_logger.formatter = custom_formatter
    custom_logger.level = Logger::INFO
  end

  shared_examples 'preserves custom logger formatter' do |server_class, server_args|
    context "with #{server_class}" do
      it 'preserves custom formatter when logger is provided' do
        server = server_class.new(**server_args, logger: custom_logger)

        expect(server.instance_variable_get(:@logger)).to eq(custom_logger)
        expect(server.instance_variable_get(:@logger).formatter).to eq(custom_formatter)
      end

      it 'sets progname to class name when custom logger is provided' do
        server = server_class.new(**server_args, logger: custom_logger)

        expect(server.instance_variable_get(:@logger).progname).to eq(server_class.name)
      end

      it 'creates default logger with standard formatter when no logger provided' do
        server = server_class.new(**server_args)
        logger = server.instance_variable_get(:@logger)

        expect(logger).to be_a(Logger)
        expect(logger).not_to eq(custom_logger)
        expect(logger.progname).to eq(server_class.name)
        expect(logger.level).to eq(Logger::WARN)
      end

      it 'default logger formatter produces expected output format' do
        server = server_class.new(**server_args)
        logger = server.instance_variable_get(:@logger)

        # Capture logger output
        output = StringIO.new
        logger.instance_variable_set(:@logdev, Logger::LogDevice.new(output))

        # Use warn level since default logger level is WARN
        logger.warn('test message')

        expect(output.string).to match(/WARN \[#{server_class.name}\] test message\n/)
      end

      it 'custom logger formatter produces expected output format' do
        server = server_class.new(**server_args, logger: custom_logger)
        logger = server.instance_variable_get(:@logger)

        # Capture logger output
        output = StringIO.new
        logger.instance_variable_set(:@logdev, Logger::LogDevice.new(output))

        logger.info('test message')

        expect(output.string).to match(
          /CUSTOM-FORMAT: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] #{server_class.name}: test message\n/
        )
      end
    end
  end

  # Test all server implementations
  include_examples 'preserves custom logger formatter', MCPClient::ServerStdio, { command: 'echo' }
  include_examples 'preserves custom logger formatter', MCPClient::ServerHTTP, { base_url: 'http://example.com' }
  include_examples 'preserves custom logger formatter', MCPClient::ServerSSE, { base_url: 'http://example.com/sse' }
  include_examples 'preserves custom logger formatter', MCPClient::ServerStreamableHTTP, { base_url: 'http://example.com' }

  describe 'ServerBase#initialize_logger' do
    let(:test_server_class) do
      Class.new(MCPClient::ServerBase) do
        def initialize(logger: nil)
          super(name: 'test')
          initialize_logger(logger)
        end

        # Implement required abstract methods
        def connect # rubocop:disable Naming/PredicateMethod
          true
        end

        def list_tools
          []
        end

        def call_tool(_name, _params)
          {}
        end

        def cleanup; end

        def rpc_request(_method, _params = {})
          {}
        end

        def rpc_notify(_method, _params = {}); end
      end
    end

    it 'is a protected method' do
      expect(MCPClient::ServerBase.protected_instance_methods).to include(:initialize_logger)
    end

    it 'returns the logger instance' do
      server = test_server_class.new(logger: custom_logger)

      # Since it's protected, we can't test the return value directly,
      # but we can verify the logger was set correctly
      expect(server.instance_variable_get(:@logger)).to eq(custom_logger)
    end

    it 'handles nil logger parameter' do
      server = test_server_class.new(logger: nil)
      logger = server.instance_variable_get(:@logger)

      expect(logger).to be_a(Logger)
      expect(logger.level).to eq(Logger::WARN)
      expect(logger.progname).to eq(test_server_class.name)
    end

    it 'does not modify logger level when custom logger is provided' do
      custom_logger.level = Logger::DEBUG
      server = test_server_class.new(logger: custom_logger)

      expect(server.instance_variable_get(:@logger).level).to eq(Logger::DEBUG)
    end

    it 'does not modify other logger properties when custom logger is provided' do
      custom_logger.level = Logger::ERROR
      custom_datetime_format = '%Y-%m-%d'
      custom_logger.datetime_format = custom_datetime_format

      server = test_server_class.new(logger: custom_logger)
      logger = server.instance_variable_get(:@logger)

      expect(logger.level).to eq(Logger::ERROR)
      expect(logger.datetime_format).to eq(custom_datetime_format)
      expect(logger.formatter).to eq(custom_formatter)
    end
  end

  describe 'MCPClient::Client logger handling' do
    it 'preserves a caller-supplied logger formatter (does not reconfigure the app logger)' do
      client = MCPClient::Client.new(logger: custom_logger)

      logger = client.instance_variable_get(:@logger)
      expect(logger).to eq(custom_logger)
      expect(logger.formatter).to eq(custom_formatter)
    end

    it 'tags the caller-supplied logger progname without touching its level' do
      custom_logger.level = Logger::ERROR
      client = MCPClient::Client.new(logger: custom_logger)

      logger = client.instance_variable_get(:@logger)
      expect(logger.progname).to eq(MCPClient::Client.name)
      expect(logger.level).to eq(Logger::ERROR)
    end

    it 'installs the default formatter only on a logger it creates' do
      client = MCPClient::Client.new
      logger = client.instance_variable_get(:@logger)

      output = StringIO.new
      logger.instance_variable_set(:@logdev, Logger::LogDevice.new(output))
      logger.warn('hello')

      expect(output.string).to match(/WARN \[#{MCPClient::Client.name}\] hello\n/)
    end
  end

  describe 'logger usage in server operations' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: 'http://example.com', logger: custom_logger) }

    before do
      # Mock HTTP requests to avoid actual network calls
      stub_request(:post, 'http://example.com/rpc')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { jsonrpc: '2.0', id: 1, result: { serverInfo: {}, capabilities: {} } }.to_json
        )
    end

    it 'uses the custom logger during server operations' do
      # Capture logger output
      output = StringIO.new
      custom_logger.instance_variable_set(:@logdev, Logger::LogDevice.new(output))

      server.connect

      # Verify that custom formatter was used in log output
      expect(output.string).to match(/CUSTOM-FORMAT:.*MCPClient::ServerHTTP/)
    end
  end

  describe 'edge cases' do
    it 'handles logger with nil formatter' do
      custom_logger.formatter = nil
      server = MCPClient::ServerHTTP.new(base_url: 'http://example.com', logger: custom_logger)

      expect(server.instance_variable_get(:@logger).formatter).to be_nil
      expect(server.instance_variable_get(:@logger).progname).to eq('MCPClient::ServerHTTP')
    end

    it 'handles logger that raises during progname assignment' do
      problematic_logger = double('logger')
      allow(problematic_logger).to receive(:progname=).and_raise(StandardError.new('test error'))

      expect do
        MCPClient::ServerHTTP.new(base_url: 'http://example.com', logger: problematic_logger)
      end.to raise_error(StandardError, 'test error')
    end

    it 'works with logger subclasses' do
      custom_logger_class = Class.new(Logger) do
        def custom_method
          'custom'
        end
      end

      custom_logger_instance = custom_logger_class.new($stdout)
      custom_logger_instance.formatter = custom_formatter

      server = MCPClient::ServerHTTP.new(base_url: 'http://example.com', logger: custom_logger_instance)
      logger = server.instance_variable_get(:@logger)

      expect(logger).to be_a(custom_logger_class)
      expect(logger.custom_method).to eq('custom')
      expect(logger.formatter).to eq(custom_formatter)
    end
  end
end
