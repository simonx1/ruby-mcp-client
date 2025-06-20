# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Auth do
  describe MCPClient::Auth::Token do
    describe '#initialize' do
      it 'creates token with required parameters' do
        token = described_class.new(access_token: 'test_token')
        expect(token.access_token).to eq('test_token')
        expect(token.token_type).to eq('Bearer')
      end

      it 'calculates expires_at from expires_in' do
        freeze_time = Time.parse('2024-01-01 12:00:00 UTC')
        allow(Time).to receive(:now).and_return(freeze_time)

        token = described_class.new(access_token: 'test_token', expires_in: 3600)
        expect(token.expires_at).to eq(freeze_time + 3600)
      end
    end

    describe '#expired?' do
      it 'returns false when no expiration time is set' do
        token = described_class.new(access_token: 'test_token')
        expect(token).not_to be_expired
      end

      it 'returns true when token is expired' do
        token = described_class.new(access_token: 'test_token', expires_in: 3600)
        token.instance_variable_set(:@expires_at, Time.now - 1)
        expect(token).to be_expired
      end

      it 'returns false when token is not expired' do
        token = described_class.new(access_token: 'test_token', expires_in: 3600)
        token.instance_variable_set(:@expires_at, Time.now + 1800)
        expect(token).not_to be_expired
      end
    end

    describe '#expires_soon?' do
      it 'returns true when token expires within 5 minutes' do
        token = described_class.new(access_token: 'test_token', expires_in: 3600)
        token.instance_variable_set(:@expires_at, Time.now + 200) # 3.33 minutes
        expect(token).to be_expires_soon
      end

      it 'returns false when token expires after 5 minutes' do
        token = described_class.new(access_token: 'test_token', expires_in: 3600)
        token.instance_variable_set(:@expires_at, Time.now + 400) # 6.67 minutes
        expect(token).not_to be_expires_soon
      end
    end

    describe '#to_header' do
      it 'formats authorization header value' do
        token = described_class.new(access_token: 'test_token', token_type: 'Bearer')
        expect(token.to_header).to eq('Bearer test_token')
      end
    end

    describe '#to_h and #from_h' do
      it 'round-trips token data' do
        original = described_class.new(
          access_token: 'test_token',
          token_type: 'Bearer',
          expires_in: 3600,
          scope: 'read write',
          refresh_token: 'refresh123'
        )

        hash = original.to_h
        restored = described_class.from_h(hash)

        expect(restored.access_token).to eq(original.access_token)
        expect(restored.token_type).to eq(original.token_type)
        expect(restored.expires_in).to eq(original.expires_in)
        expect(restored.scope).to eq(original.scope)
        expect(restored.refresh_token).to eq(original.refresh_token)
      end
    end
  end

  describe MCPClient::Auth::ClientMetadata do
    describe '#initialize' do
      it 'creates metadata with default values' do
        metadata = described_class.new(redirect_uris: ['http://localhost:8080/callback'])
        expect(metadata.redirect_uris).to eq(['http://localhost:8080/callback'])
        expect(metadata.token_endpoint_auth_method).to eq('none')
        expect(metadata.grant_types).to eq(%w[authorization_code refresh_token])
        expect(metadata.response_types).to eq(['code'])
      end
    end

    describe '#to_h' do
      it 'converts to hash and excludes nil values' do
        metadata = described_class.new(
          redirect_uris: ['http://localhost:8080/callback'],
          scope: 'read write'
        )
        hash = metadata.to_h
        expect(hash).to include(
          redirect_uris: ['http://localhost:8080/callback'],
          scope: 'read write'
        )
        expect(hash).not_to have_key(:client_id)
      end
    end
  end

  describe MCPClient::Auth::PKCE do
    describe '#initialize' do
      it 'generates code verifier and challenge' do
        pkce = described_class.new
        expect(pkce.code_verifier).to be_a(String)
        expect(pkce.code_challenge).to be_a(String)
        expect(pkce.code_challenge_method).to eq('S256')
      end

      it 'generates different values each time' do
        pkce1 = described_class.new
        pkce2 = described_class.new
        expect(pkce1.code_verifier).not_to eq(pkce2.code_verifier)
        expect(pkce1.code_challenge).not_to eq(pkce2.code_challenge)
      end
    end
  end
end
