# frozen_string_literal: true

require 'spec_helper'

# MCP 2025-11-25 roots spec (client/roots.mdx, Data Types - Root):
#   "uri: Unique identifier for the root. This MUST be a file:// URI in the
#    current specification."
# Security Considerations: "Clients MUST: ... Validate all root URIs to
# prevent path traversal".
# schema.ts Root also declares an optional `_meta?: { [key: string]: unknown }`.
RSpec.describe 'Root URI validation and _meta support' do
  describe MCPClient::Root do
    describe 'URI validation' do
      it 'accepts a file:// URI' do
        root = described_class.new(uri: 'file:///home/user/project')
        expect(root.uri).to eq('file:///home/user/project')
      end

      it 'accepts a file:// URI with a name' do
        root = described_class.new(uri: 'file:///home/user/project', name: 'My Project')
        expect(root.name).to eq('My Project')
      end

      it 'accepts an uppercase FILE scheme (schemes are case-insensitive)' do
        root = described_class.new(uri: 'FILE:///home/user/project')
        expect(root.uri).to eq('FILE:///home/user/project')
      end

      it 'rejects an http:// URI' do
        expect do
          described_class.new(uri: 'http://example.com/project')
        end.to raise_error(ArgumentError, %r{file://})
      end

      it 'rejects an https:// URI' do
        expect do
          described_class.new(uri: 'https://example.com/project')
        end.to raise_error(ArgumentError, %r{file://})
      end

      it 'rejects a relative path with no scheme' do
        expect do
          described_class.new(uri: 'relative/path')
        end.to raise_error(ArgumentError, %r{file://})
      end

      it 'rejects an absolute filesystem path with no scheme' do
        expect do
          described_class.new(uri: '/home/user/project')
        end.to raise_error(ArgumentError, %r{file://})
      end

      it 'rejects a nil uri' do
        expect do
          described_class.new(uri: nil)
        end.to raise_error(ArgumentError)
      end

      it 'rejects a non-string uri' do
        expect do
          described_class.new(uri: 123)
        end.to raise_error(ArgumentError)
      end

      it 'rejects an unparseable uri' do
        expect do
          described_class.new(uri: 'file://<not a uri>')
        end.to raise_error(ArgumentError)
      end

      it 'rejects a file:// URI containing ".." path traversal segments' do
        expect do
          described_class.new(uri: 'file:///home/user/../../etc/passwd')
        end.to raise_error(ArgumentError, /traversal|\.\./)
      end

      it 'rejects invalid URIs in from_json too' do
        expect do
          described_class.from_json({ 'uri' => 'https://example.com' })
        end.to raise_error(ArgumentError, %r{file://})
      end

      it 'rejects from_json input with a missing uri' do
        expect do
          described_class.from_json({ 'name' => 'No URI' })
        end.to raise_error(ArgumentError)
      end
    end

    describe '_meta support' do
      it 'accepts an optional meta kwarg and exposes it' do
        root = described_class.new(uri: 'file:///path', meta: { 'key' => 'value' })
        expect(root.meta).to eq({ 'key' => 'value' })
      end

      it 'defaults meta to nil' do
        root = described_class.new(uri: 'file:///path')
        expect(root.meta).to be_nil
      end

      it 'parses _meta in from_json (string keys)' do
        root = described_class.from_json({ 'uri' => 'file:///path', '_meta' => { 'a' => 1 } })
        expect(root.meta).to eq({ 'a' => 1 })
      end

      it 'parses _meta in from_json (symbol keys)' do
        root = described_class.from_json({ uri: 'file:///path', _meta: { 'a' => 1 } })
        expect(root.meta).to eq({ 'a' => 1 })
      end

      it 'includes _meta in to_h when present' do
        root = described_class.new(uri: 'file:///path', name: 'Test', meta: { 'a' => 1 })
        expect(root.to_h).to eq({ 'uri' => 'file:///path', 'name' => 'Test', '_meta' => { 'a' => 1 } })
      end

      it 'omits _meta from to_h when absent' do
        root = described_class.new(uri: 'file:///path')
        expect(root.to_h).to eq({ 'uri' => 'file:///path' })
      end

      it 'round-trips _meta through from_json and to_h' do
        json = { 'uri' => 'file:///path', 'name' => 'Test', '_meta' => { 'trace' => 'abc' } }
        expect(described_class.from_json(json).to_h).to eq(json)
      end

      it 'considers _meta in equality' do
        root1 = described_class.new(uri: 'file:///path', meta: { 'a' => 1 })
        root2 = described_class.new(uri: 'file:///path', meta: { 'a' => 2 })
        root3 = described_class.new(uri: 'file:///path', meta: { 'a' => 1 })

        expect(root1).not_to eq(root2)
        expect(root1).to eq(root3)
        expect(root1.hash).to eq(root3.hash)
      end
    end
  end

  describe MCPClient::Client do
    it 'raises ArgumentError when constructed with a non-file:// root' do
      expect do
        MCPClient::Client.new(roots: [{ uri: 'https://example.com/project' }])
      end.to raise_error(ArgumentError, %r{file://})
    end

    it 'raises ArgumentError when roots= is given a non-file:// root' do
      client = MCPClient::Client.new
      expect do
        client.roots = [MCPClient::Root.new(uri: 'file:///ok'), { 'uri' => '/no/scheme' }]
      end.to raise_error(ArgumentError, %r{file://})
    end

    it 'serializes _meta in the roots/list response' do
      client = MCPClient::Client.new(roots: [{ 'uri' => 'file:///path', '_meta' => { 'k' => 'v' } }])
      response = client.send(:handle_roots_list_request, 1, {})

      expect(response).to eq({ 'roots' => [{ 'uri' => 'file:///path', '_meta' => { 'k' => 'v' } }] })
    end
  end
end
