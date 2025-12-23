# frozen_string_literal: true

require_relative 'lib/mcp_client/version'

Gem::Specification.new do |spec|
  spec.name          = 'ruby-mcp-client'
  spec.version       = MCPClient::VERSION
  spec.authors       = ['Szymon Kurcab']
  spec.email         = ['szymon.kurcab@gmail.com']

  spec.summary       = 'A Ruby client for the Model Context Protocol (MCP)'
  spec.description   = 'Ruby client library for integrating with Model Context Protocol (MCP) servers ' \
                       'to access and invoke tools from AI assistants'
  spec.homepage      = 'https://github.com/simonx1/ruby-mcp-client'
  spec.license       = 'MIT'

  spec.files         = Dir.glob('lib/**/*.rb') + ['README.md', 'LICENSE']
  spec.required_ruby_version = '>= 3.2.0'
  spec.require_paths = ['lib']
  # HTTP instrumentation
  spec.add_dependency 'faraday', '~> 2.0'
  spec.add_dependency 'faraday-follow_redirects', '~> 0.3'
  spec.add_dependency 'faraday-retry', '~> 2.0'

  spec.add_development_dependency 'rdoc', '~> 7.0'
  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.62'
  spec.add_development_dependency 'yard', '~> 0.9.34'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
