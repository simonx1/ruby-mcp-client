# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'open3'

# The fixture server is a stand-in for a real filesystem MCP server, so its
# root containment must behave like one: a lexical string prefix accepts a
# sibling directory whose name merely starts with the root, and an unresolved
# path follows a symlink straight out of the root.
RSpec.describe 'fake_filesystem_mcp_server root containment' do
  let(:server_path) { File.expand_path('fake_filesystem_mcp_server.rb', __dir__) }

  around do |example|
    Dir.mktmpdir('fs-fixture-') do |base|
      @base = base
      @root = File.join(base, 'root')
      FileUtils.mkdir_p(@root)
      File.write(File.join(@root, 'inside.txt'), "inside\n")
      example.run
    end
  end

  # Drive the stub over stdio the way the client does and return the parsed
  # response to the single request.
  def call_tool(name, args)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: args } }
    out, = Open3.capture2(RbConfig.ruby, server_path, @root, stdin_data: "#{JSON.generate(request)}\n")
    messages = out.lines.filter_map do |l|
      JSON.parse(l)
    rescue JSON::ParserError
      nil
    end
    messages.find { |m| m['id'] == 1 } || {}
  end

  it 'lists a directory inside the root' do
    response = call_tool('list_directory', { 'path' => '.' })

    expect(response['error']).to be_nil
    expect(response.dig('result', 'content', 0, 'text')).to include('inside.txt')
  end

  it 'denies a sibling directory whose name merely starts with the root path' do
    sibling = "#{@root}-sibling"
    FileUtils.mkdir_p(sibling)
    File.write(File.join(sibling, 'secret.txt'), "outside\n")

    response = call_tool('list_directory', { 'path' => '../root-sibling' })

    expect(response.dig('error', 'message')).to eq('Access denied')
  end

  it 'denies a path that escapes the root through a symlink' do
    outside = File.join(@base, 'outside')
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, 'secret.txt'), "outside\n")
    File.symlink(outside, File.join(@root, 'link'))

    response = call_tool('list_directory', { 'path' => 'link' })

    expect(response.dig('error', 'message')).to eq('Access denied')
  end

  it 'denies a parent-directory traversal' do
    response = call_tool('list_directory', { 'path' => '..' })

    expect(response.dig('error', 'message')).to eq('Access denied')
  end
end
