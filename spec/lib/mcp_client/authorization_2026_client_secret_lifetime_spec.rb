# frozen_string_literal: true

require 'spec_helper'

# RFC 7591 Section 3.2.1: client_secret_expires_at is "the time at which the
# client secret will expire ... or 0 if it will not expire". A registration
# that says the secret never expires must not be read as one that expired at
# the epoch.
RSpec.describe 'MCP 2026-07-28 authorization — client secret lifetime' do
  def client_info(expires_at)
    MCPClient::Auth::ClientInfo.new(
      client_id: 'dyn', client_secret: 'secret', client_secret_expires_at: expires_at,
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: ['http://localhost:8080/callback'])
    )
  end

  it 'treats 0 as a secret that never expires' do
    expect(client_info(0).client_secret_expired?).to be false
  end

  it 'still reports a secret whose expiry has passed' do
    expect(client_info(Time.now.to_i - 1).client_secret_expired?).to be true
  end

  it 'still reports a secret whose expiry is ahead as live' do
    expect(client_info(Time.now.to_i + 3600).client_secret_expired?).to be false
  end

  it 'treats an absent expiry as no expiry' do
    expect(client_info(nil).client_secret_expired?).to be false
  end

  it 'survives a round trip through the serialized form' do
    restored = MCPClient::Auth::ClientInfo.from_h(client_info(0).to_h)
    expect(restored.client_secret_expired?).to be false
  end
end
