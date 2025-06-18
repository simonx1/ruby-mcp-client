# frozen_string_literal: true

begin
  require 'bundler/setup'
rescue LoadError => e
  puts "Bundler setup failed: #{e.message}"
end
require 'rspec'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'mcp_client'
require 'webmock/rspec'
require 'vcr'
require 'openai'

# Configure VCR for HTTP interaction recording
VCR.configure do |config|
  config.cassette_library_dir = File.expand_path('cassettes', __dir__)
  config.hook_into :webmock
  config.filter_sensitive_data('<OPENAI_API_KEY>') { ENV.fetch('OPENAI_API_KEY', 'fake') }
  config.configure_rspec_metadata!
  config.ignore_localhost = true
  # Allow external connections when running integration tests
  config.allow_http_connections_when_no_cassette = true
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Reset WebMock before each test to ensure test isolation
  config.before(:each) do
    WebMock.reset!
    WebMock.disable_net_connect!(allow_localhost: true)

    # Clear any cached HTTP connections that might persist between tests
    Faraday::ConnectionPool.instance_variable_set(:@connections, {}) if defined?(Faraday::ConnectionPool)
  end

  # Disable WebMock for integration tests
  config.before(:each, integration: true) do
    WebMock.allow_net_connect!
  end

  config.after(:each, integration: true) do
    WebMock.disable_net_connect!(allow_localhost: true)
  end
end
