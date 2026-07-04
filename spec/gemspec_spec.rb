# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ruby-mcp-client.gemspec' do
  let(:gemspec) do
    Gem::Specification.load(File.expand_path('../ruby-mcp-client.gemspec', __dir__))
  end

  it 'loads without error' do
    expect(gemspec).to be_a(Gem::Specification)
  end

  # base64 became a bundled (non-default) gem in Ruby 3.4. The library requires
  # it (OAuth/PKCE, audio and resource content helpers), so it must be a
  # declared runtime dependency or `require 'base64'` fails under Bundler on
  # Ruby >= 3.4.
  it 'declares base64 as a runtime dependency' do
    dep = gemspec.dependencies.find { |d| d.name == 'base64' }
    expect(dep).not_to be_nil
    expect(dep.type).to eq(:runtime)
  end

  it 'requires base64 at load time' do
    expect { require 'base64' }.not_to raise_error
    expect(defined?(Base64)).to eq('constant')
  end
end
