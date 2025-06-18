# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'rbconfig'

RSpec.describe 'MCPClient integration with ruby-openai', :integration,
               vcr: { cassette_name: 'openai_mcp_integration' } do
  let(:local_path) { Dir.pwd }
  let(:mcp_client) do
    MCPClient.create_client(
      mcp_server_configs: [
        # Use JSON-RPC stdio to communicate with the Node MCP filesystem server
        MCPClient.stdio_config(
          command: [RbConfig.ruby, File.expand_path('../support/fake_filesystem_mcp_server.rb', __dir__), local_path]
        )
      ]
    )
  end

  let(:openai) do
    OpenAI::Client.new(
      access_token: ENV.fetch('OPENAI_API_KEY', 'fake')
    )
  end

  after do
    mcp_client.cleanup
  end

  it 'queries local file system MCP to get a list of files' do
    # Prepare function definitions from MCP tools
    tools = mcp_client.to_openai_tools

    # Build chat messages
    messages = [
      { role: 'system', content: 'You can call MCP tools.' },
      { role: 'user', content: 'List all files in current directory' }
    ]

    # Call OpenAI Chat API with function definitions
    response = openai.chat(parameters: {
                             model: 'gpt-4o-mini',
                             messages: messages,
                             tools: tools,
                             tool_choice: 'auto'
                           })

    # Extract the function call from the response
    tool_call = response.dig('choices', 0, 'message', 'tool_calls', 0)
    expect(tool_call).not_to be_nil
    expect(tool_call['type']).to eq('function')
    expect(tool_call['function']['name']).to eq('list_directory')

    # Invoke the MCP tool based on the function call
    function_details = tool_call['function']
    name = function_details['name']
    args = JSON.parse(function_details['arguments'])
    result = mcp_client.call_tool(name, args)

    # Check results: raw content from filesystem server
    expect(result).to be_a(Hash)
    expect(result).to have_key('content')
    # Combine any text chunks
    listing = result['content'].map { |chunk| chunk['text'] }.join
    expect(listing).to include('[DIR] lib')
    expect(listing).to include('[DIR] spec')
    expect(listing).to include('[FILE] README.md')

    # Add a tool result message back to the conversation
    messages << { role: 'assistant', tool_calls: [tool_call] }
    messages << { role: 'tool', tool_call_id: tool_call['id'], name: name, content: result.to_json }

    # Get the final response
    final_response = openai.chat(parameters: {
                                   model: 'gpt-4o-mini',
                                   messages: messages
                                 })
    response_content = final_response.dig('choices', 0, 'message', 'content')

    # Response content assertions
    expect(response_content).to include('lib')
    expect(response_content).to include('spec')
    expect(response_content).to include('README.md')

    expect(mcp_client.to_openai_tools).to all(be_a(Hash))
    expect(mcp_client.to_openai_tools.first).to have_key(:type)
    expect(mcp_client.to_openai_tools.first).to have_key(:function)
  end
end
