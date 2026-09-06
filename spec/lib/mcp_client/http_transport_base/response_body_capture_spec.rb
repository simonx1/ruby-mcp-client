# frozen_string_literal: true

require 'spec_helper'

# The innermost capture middleware, driven directly: what it keeps of a
# response body, and what it refuses to keep once the request's deadline has
# passed. A chunk kept past the deadline would be offered to the salvage as a
# delivered answer, settling a request whose caller had already stopped
# waiting for one.
RSpec.describe MCPClient::HttpTransportBase::ResponseBodyCapture do
  let(:buffer) { +'' }
  let(:state) { { mcp_body_buffer: buffer } }

  # A minimal stand-in for the Faraday env the middleware reads and writes.
  def env_for(state)
    request = Struct.new(:context, :on_data).new(state, nil)
    Struct.new(:request, :body).new(request, nil)
  end

  def feed(state, chunk)
    env = env_for(state)
    described_class.new(->(e) { e }).on_request(env)
    env.request.on_data.call(chunk, chunk.bytesize, env)
  end

  it 'keeps a chunk that arrives while the deadline is still ahead' do
    state[:mcp_deadline] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30

    feed(state, 'still in time')

    expect(state[:mcp_body_buffer]).to eq('still in time')
  end

  it 'refuses a chunk that arrives after the deadline, and keeps none of it' do
    state[:mcp_deadline] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1

    expect { feed(state, 'too late to matter') }
      .to raise_error(Faraday::TimeoutError, /deadline/)
    expect(state[:mcp_body_buffer]).to be_empty
  end

  it 'keeps a chunk when the request carries no deadline at all' do
    feed(state, 'unbounded')

    expect(state[:mcp_body_buffer]).to eq('unbounded')
  end
end
