# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'json'

RSpec.describe MCPClient::ConfigParser do
  let(:logger) { instance_double(Logger, warn: nil) }

  describe '#parse' do
    context 'with valid JSON file' do
      it 'parses a single server object' do
        with_temp_file('{"type":"stdio","command":"echo"}') do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result.size).to eq(1)
          expect(result['0'][:type]).to eq('stdio')
          expect(result['0'][:command]).to eq('echo')
        end
      end

      it 'parses an array of server objects' do
        content = '[
          {"type":"stdio","command":"echo"},
          {"type":"sse","url":"http://example.com"}
        ]'

        with_temp_file(content) do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result.size).to eq(2)
          expect(result['0'][:type]).to eq('stdio')
          expect(result['1'][:type]).to eq('sse')
          expect(result['1'][:url]).to eq('http://example.com')
        end
      end

      it 'parses mcpServers object structure' do
        content = '{
          "mcpServers": {
            "server1": {"type":"stdio","command":"echo"},
            "server2": {"type":"sse","url":"http://example.com"}
          }
        }'

        with_temp_file(content) do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result.size).to eq(2)
          expect(result['server1'][:type]).to eq('stdio')
          expect(result['server2'][:type]).to eq('sse')
          expect(result['server2'][:url]).to eq('http://example.com')
        end
      end
    end

    context 'with invalid JSON file' do
      it 'raises ParserError for invalid JSON' do
        with_temp_file('{"invalid json') do |path|
          parser = described_class.new(path, logger: logger)
          expect { parser.parse }.to raise_error(JSON::ParserError)
        end
      end

      it 'raises ENOENT for missing file' do
        parser = described_class.new('/non/existent/file.json', logger: logger)
        expect { parser.parse }.to raise_error(Errno::ENOENT)
      end
    end

    context 'with inference of server types' do
      it 'infers stdio type from command presence' do
        with_temp_file('{"command":"echo","args":["hello"]}') do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result['0'][:type]).to eq('stdio')
          expect(result['0'][:command]).to eq('echo')
          expect(result['0'][:args]).to eq(['hello'])
          expect(logger).to have_received(:warn).with(/inferring as 'stdio'/)
        end
      end

      it 'infers streamable_http type from url presence by default' do
        with_temp_file('{"url":"http://example.com"}') do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result['0'][:type]).to eq('streamable_http')
          expect(result['0'][:url]).to eq('http://example.com')
          expect(logger).to have_received(:warn).with(/inferring as 'streamable_http'/)
        end
      end

      it 'infers sse type when url contains "sse"' do
        with_temp_file('{"url":"http://example.com/sse"}') do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result['0'][:type]).to eq('sse')
          expect(result['0'][:url]).to eq('http://example.com/sse')
          expect(logger).to have_received(:warn).with(/inferring as 'sse'/)
        end
      end
    end

    context 'with input format edge cases' do
      it 'handles non-string commands' do
        with_temp_file('{"type":"stdio","command":123}') do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result['0'][:command]).to eq('123')
          expect(logger).to have_received(:warn).with(/not a string/)
        end
      end

      it 'handles non-array args' do
        with_temp_file('{"type":"stdio","command":"echo","args":"hello"}') do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result['0'][:args]).to eq(['hello'])
          expect(logger).to have_received(:warn).with(/not an array/)
        end
      end

      it 'skips unrecognized server types' do
        with_temp_file('{"type":"unknown","command":"echo"}') do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result).to be_empty
          expect(logger).to have_received(:warn).with(/Unrecognized type/)
        end
      end

      it 'filters out reserved keys from server configs' do
        content = '{
          "mcpServers": {
            "server1": {
              "type": "sse",
              "url": "http://example.com",
              "comment": "This is a comment",
              "description": "This should be removed"
            }
          }
        }'

        with_temp_file(content) do |path|
          parser = described_class.new(path, logger: logger)
          result = parser.parse

          expect(result['server1'].keys).to match_array(%i[type url headers name])
          expect(result['server1']).not_to have_key(:comment)
          expect(result['server1']).not_to have_key(:description)
        end
      end
    end
  end

  # Helper method to create a temporary file with given content
  def with_temp_file(content)
    file = Tempfile.new(['mcp_config', '.json'])
    file.write(content)
    file.close

    begin
      yield file.path
    ensure
      file.unlink
    end
  end
end
