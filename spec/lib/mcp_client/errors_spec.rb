# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Errors do
  it 'defines MCPError and its subclasses' do
    expect(MCPClient::Errors::MCPError).to be < StandardError
    expect(MCPClient::Errors::ToolNotFound).to be < MCPClient::Errors::MCPError
    expect(MCPClient::Errors::ServerNotFound).to be < MCPClient::Errors::MCPError
    expect(MCPClient::Errors::ToolCallError).to be < MCPClient::Errors::MCPError
    expect(MCPClient::Errors::ConnectionError).to be < MCPClient::Errors::MCPError
    expect(MCPClient::Errors::ServerError).to be < MCPClient::Errors::MCPError
    expect(MCPClient::Errors::TransportError).to be < MCPClient::Errors::MCPError
    expect(MCPClient::Errors::PromptGetError).to be < MCPClient::Errors::MCPError
    expect(MCPClient::Errors::PromptGetError).to be < MCPClient::Errors::MCPError
    expect(MCPClient::Errors::AmbiguousPromptName).to be < MCPClient::Errors::MCPError
  end
end
