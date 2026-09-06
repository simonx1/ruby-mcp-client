# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 JSON Schema handling, thirty-fourth round.
#
# A dynamic reference binds to the outermost schema resource in the *dynamic
# scope* — the resources evaluation actually entered on the way to it (JSON
# Schema 2020-12 Core Section 8.2.3.2; 2019-09 Section 8.2.4.2.2 for
# `$recursiveRef`). A resource the instance never enters declares nothing
# for it, so a duplicate anchor elsewhere in the document decides nothing.
# `contains` produces the item annotations `unevaluatedItems` reads in
# 2020-12 and not in 2019-09, and a pattern whose ECMA-262 meaning Ruby's
# engine cannot be made to reproduce is refused rather than answered wrongly.
RSpec.describe 'MCP 2026-07-28 JSON Schema dynamic scope, contains annotations, patterns (round 34)' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft2019) { MCPClient::SchemaValidator::DRAFT_2019_09 }

  def valid?(data, schema)
    errors = validator.validate(data, schema)
    expect(errors).not_to include(a_string_matching(/aborted|not supported/)), errors.inspect
    errors.empty?
  end

  def expect_verdicts(schema, valid:, invalid:)
    valid.each { |data| expect(valid?(data, schema)).to be(true), "expected #{data.inspect} to conform" }
    invalid.each { |data| expect(valid?(data, schema)).to be(false), "expected #{data.inspect} to be rejected" }
  end

  describe 'the dynamic scope is the resources evaluation entered' do
    # Two resources declare `node`; only `a` is ever entered, so the
    # reference inside it binds to `a` and nothing about `b` reaches the
    # verdict. Deciding this statically ("several non-root declarations, so
    # the path would have to choose") left the reference unevaluated and the
    # instance wrongly accepted.
    let(:unused_duplicate) do
      { '$ref' => 'https://example.com/a',
        '$defs' => {
          'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node', 'type' => 'object',
                   'properties' => { 'child' => { '$dynamicRef' => '#node' } } },
          'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node', 'type' => 'string' }
        } }
    end

    it 'ignores a duplicate anchor in a resource the instance never enters' do
      expect_verdicts(unused_duplicate,
                      valid: [{ 'child' => {} }, { 'child' => { 'child' => {} } }],
                      invalid: [{ 'child' => 1 }, { 'child' => { 'child' => 'x' } }])
    end

    it 'inverts that verdict under not, rather than accepting both sides' do
      expect_verdicts({ 'not' => unused_duplicate },
                      valid: [{ 'child' => 1 }],
                      invalid: [{ 'child' => {} }])
    end

    it 'reports no unsupported keyword for it, so :strict can gate on the verdict' do
      expect(validator.unsupported_keywords(unused_duplicate)).to be_empty
    end

    # The specification's own illustration: the outer resource overrides the
    # anchor the inner one declares, so the reference inside the inner
    # resource re-binds outward to whichever resource the evaluation began at.
    let(:tree) do
      { '$id' => 'https://example.com/tree', '$dynamicAnchor' => 'node',
        'type' => 'object',
        'properties' => { 'data' => true,
                          'children' => { 'type' => 'array', 'items' => { '$dynamicRef' => '#node' } } } }
    end

    def strict_tree(tree)
      { '$id' => 'https://example.com/strict-tree', '$dynamicAnchor' => 'node',
        '$ref' => 'https://example.com/tree', 'unevaluatedProperties' => false,
        '$defs' => { 'tree' => tree } }
    end

    it 'binds a reference met inside an entered resource to the outermost declaration' do
      expect_verdicts(strict_tree(tree),
                      valid: [{ 'data' => 1 }, { 'data' => 1, 'children' => [{ 'data' => 2 }] }],
                      invalid: [{ 'data' => 1, 'extra' => 2 },
                                { 'data' => 1, 'children' => [{ 'data' => 2, 'extra' => 3 }] }])
    end

    it 'binds to the entered resource itself when nothing outer declares the anchor' do
      expect_verdicts({ '$id' => 'https://example.com/plain', '$ref' => 'https://example.com/tree',
                        '$defs' => { 'tree' => tree } },
                      valid: [{ 'data' => 1, 'extra' => 2 },
                              { 'children' => [{ 'data' => 2, 'extra' => 3 }] }],
                      invalid: [{ 'children' => [1] }])
    end

    # 2019-09 spells the same rule with `$recursiveRef`/`$recursiveAnchor`.
    it 'follows the 2019-09 recursive reference outward the same way' do
      inner = { '$id' => 'https://example.com/r-tree', '$recursiveAnchor' => true,
                'type' => 'object',
                'properties' => { 'data' => true,
                                  'children' => { 'type' => 'array',
                                                  'items' => { '$recursiveRef' => '#' } } } }
      strict = { '$schema' => draft2019, '$id' => 'https://example.com/r-strict',
                 '$recursiveAnchor' => true, '$ref' => 'https://example.com/r-tree',
                 'unevaluatedProperties' => false, '$defs' => { 'tree' => inner } }
      expect(validator.unsupported_keywords(strict)).to be_empty
      expect_verdicts(strict,
                      valid: [{ 'data' => 1, 'children' => [{ 'data' => 2 }] }],
                      invalid: [{ 'data' => 1, 'children' => [{ 'data' => 2, 'extra' => 3 }] }])
    end

    it 'refuses a dynamic reference whose anchor no entered resource declares' do
      schema = { '$dynamicRef' => '#nowhere', 'type' => 'object' }
      expect(validator.validate({}, schema)).to include(a_string_matching(/\$dynamicRef/))
    end
  end

  describe 'contains annotations belong to 2020-12' do
    let(:schema) { { 'contains' => { 'type' => 'integer' }, 'unevaluatedItems' => false } }

    it 'lets a matched item satisfy unevaluatedItems under 2020-12' do
      expect_verdicts(schema, valid: [[1]], invalid: [%w[a]])
    end

    # 2019-09 Core Section 9.3.1.3: unevaluatedItems reads the annotations of
    # items/additionalItems only, so a `contains` match leaves the item
    # unevaluated and `false` refuses it. `items` still annotates there, so
    # the same array passes once something evaluates it.
    it 'does not, under 2019-09' do
      expect_verdicts(schema.merge('$schema' => draft2019), valid: [], invalid: [[1], %w[a]])
      expect_verdicts(schema.merge('$schema' => draft2019, 'items' => true), valid: [[1]], invalid: [%w[a]])
    end

    # The dialect belongs to the resource root, so it is declared there and
    # the composed branch is read under it.
    it 'inverts under not, so the dialect decides both directions' do
      expect(valid?([1], { 'not' => schema })).to be(false)
      expect(valid?([1], { '$schema' => draft2019, 'not' => schema })).to be(true)
    end
  end

  describe 'patterns whose ECMA-262 meaning Ruby cannot reproduce' do
    # ECMAScript clears the captures inside a quantified group at the start of
    # every iteration, Ruby keeps the last one that participated: "aba" is
    # valid there and "abab" is not, and Ruby's engine says the opposite of
    # both. A wrong verdict in either direction is worse than no verdict.
    let(:reset_pattern) { { 'pattern' => '^(a|(b))*\2$' } }

    it 'refuses the schema instead of answering either way' do
      %w[aba abab].each do |data|
        errors = validator.validate(data, reset_pattern)
        expect(errors).to include(a_string_matching(/cannot be evaluated faithfully/)), errors.inspect
      end
    end

    it 'never reports it as no ECMA-262 regular expression' do
      expect(validator.validate('aba', reset_pattern))
        .not_to include(a_string_matching(/is not an ECMA-262 regular expression/))
    end

    # ES2018 lookbehind is variable-length; Ruby's is not. The pattern is a
    # perfectly good ECMA-262 expression, so saying it is not one was wrong.
    it 'says the same of a variable-length lookbehind' do
      errors = validator.validate('aab', { 'pattern' => '(?<=a+)b' })
      expect(errors).to include(a_string_matching(/cannot be evaluated faithfully/))
      expect(errors).not_to include(a_string_matching(/is not an ECMA-262 regular expression/))
    end

    it 'still refuses an expression that is no regular expression at all' do
      expect(validator.validate('x', { 'pattern' => '(' }))
        .to include(a_string_matching(/is not an ECMA-262 regular expression/))
    end

    it 'keeps evaluating a back-reference to a group no quantifier repeats' do
      expect_verdicts({ 'pattern' => '^(a)(?<b>x)?\1$' }, valid: %w[aa], invalid: %w[ab])
    end

    it 'reads an astral escape written as a surrogate pair' do
      expect_verdicts({ 'pattern' => '\\uD83D\\uDE00' }, valid: ["\u{1F600}!"], invalid: %w[x])
    end
  end

  # The definition a call goes out under is the one header extraction reads,
  # and that read may bring a newer list than the client preflighted. A tool
  # whose refreshed schema declares a dialect nothing here can read must be
  # refused before it runs, not after — the retry path already was.
  describe 'a definition replaced between the preflight and the initial send' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }
    let(:json) { { 'Content-Type' => 'application/json' } }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result), headers: json }
    end

    def listing(dialect_side)
      input = { 'type' => 'object', 'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' } } }
      output = { 'type' => 'object' }
      input = { '$schema' => 'urn:unknown-dialect' }.merge(input) if dialect_side == 'input'
      output = { '$schema' => 'urn:unknown-dialect' }.merge(output) if dialect_side == 'output'
      { 'tools' => [{ 'name' => 'wipe', 'inputSchema' => input, 'outputSchema' => output }], 'ttlMs' => 0 }
    end

    %w[input output].each do |side|
      it "refuses the call before it runs when the refreshed #{side} dialect cannot be read" do
        lists = 0
        calls = 0
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          case body['method']
          when 'server/discover'
            json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                        'capabilities' => { 'tools' => {} } })
          when 'tools/list'
            # The zero-TTL list is read three times before the call goes out:
            # by list_tools, by the client's own preflight, and by the header
            # extraction that decides what the request carries. Only the last
            # one brings the unreadable dialect, so the preflight passes and
            # the transport is the only thing left to catch it.
            lists += 1
            json_response(body['id'], listing(lists >= 3 ? side : nil))
          when 'tools/call'
            calls += 1
            json_response(body['id'], { 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} })
          end
        end
        client = MCPClient::Client.new(
          mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)]
        )
        client.list_tools

        expect { client.call_tool('wipe', { 'region' => 'eu' }) }
          .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown-dialect/)
        expect(calls).to eq(0)
        expect(lists).to be >= 3
        client.cleanup
      end
    end

    it 'still sends the call when the refreshed definition stays readable' do
      lists = 0
      headers = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        when 'tools/list'
          lists += 1
          json_response(body['id'], listing(nil))
        when 'tools/call'
          headers << request.headers.select { |k, _| k.start_with?('Mcp-Param-') }
          json_response(body['id'], { 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} })
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)]
      )
      client.list_tools

      expect(client.call_tool('wipe', { 'region' => 'eu' }))
        .to eq({ 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} })
      expect(headers).to eq([{ 'Mcp-Param-Region' => 'eu' }])
      client.cleanup
    end
  end

  # MCP 2025-11-25 types structuredContent as an object, so anything else was
  # no structured content at all on a session negotiated to that revision. An
  # error result is allowed to carry none — dropping the non-object must
  # leave it an error result, not turn it into a successful one missing its
  # output.
  describe 'an error result carrying a non-object structuredContent on a legacy session' do
    let(:logger) { instance_double(Logger, warn: nil, info: nil, debug: nil, error: nil, :level= => nil) }
    let(:server) { instance_double(MCPClient::ServerStdio, modern?: false, name: 'legacy') }
    let(:tool) do
      MCPClient::Tool.new(name: 'run', description: 'd', schema: { 'type' => 'object' }, server: server,
                          output_schema: { 'type' => 'object' })
    end

    def client_with(mode)
      client = MCPClient::Client.new(mcp_server_configs: [])
      client.instance_variable_set(:@logger, logger)
      client.instance_variable_set(:@validate_structured_content, mode)
      client
    end

    [nil, 'text', 1, true, []].each do |content|
      it "returns it unchanged in :strict when structuredContent is #{content.inspect}" do
        result = { 'isError' => true, 'content' => [], 'structuredContent' => content }

        expect(client_with(:strict).send(:validate_structured_content!, tool, result)).to eq(result)
        expect(logger).not_to have_received(:warn).with(/carries no structuredContent/)
      end
    end

    it 'still refuses a successful result whose structuredContent is not an object' do
      result = { 'content' => [], 'structuredContent' => 'text' }

      expect { client_with(:strict).send(:validate_structured_content!, tool, result) }
        .to raise_error(MCPClient::Errors::ValidationError, /carries no structuredContent/)
    end

    it 'still checks an error result whose structuredContent is an object' do
      result = { 'isError' => true, 'content' => [], 'structuredContent' => { 'a' => 1 } }
      tool = MCPClient::Tool.new(name: 'run', description: 'd', schema: { 'type' => 'object' }, server: server,
                                 output_schema: { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'string' } },
                                                  'required' => ['a'] })

      expect { client_with(:strict).send(:validate_structured_content!, tool, result) }
        .to raise_error(MCPClient::Errors::ValidationError)
    end
  end
end
