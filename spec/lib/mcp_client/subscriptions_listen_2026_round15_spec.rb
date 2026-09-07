# frozen_string_literal: true

require 'spec_helper'

# Review round 15 (codex). A teardown owns exactly one process, and nothing
# else: the state it forgets and the subscriptions it parks both belong to the
# process it claimed, whatever a replacement established meanwhile.
#
# The two earlier rounds fixed halves of this. Round 13 gave the teardown a
# claim, so it dismantles the handles it took rather than the transport's
# current ones; round 14 made the hand-over reach a replacement the host
# established while the reader was still parking. What was left is the state
# on either side of the claim: `forget_torn_down_transport` checked ownership
# and then mutated without holding the lock in between, and
# `park_open_subscriptions` drained the registry rather than the claimed
# process's share of it.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 15' do
  let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def child_session
    MCPClient::ServerStdio::ChildSession.new
  end

  def claim_of(generation, session)
    MCPClient::ServerStdio::TornDownTransport.new(generation: generation, session: session)
  end

  describe 'the state a teardown forgets' do
    # The old code read the generation under the lock, released it, and only
    # then cleared @awaiting, @session and @initialized. A replacement
    # established in that window was established *after* the checks passed, so
    # the teardown went on to mark its outstanding requests dropped and leave
    # it uninitialized with no session — a live process the transport could no
    # longer name.
    it 'cannot erase a replacement established while it is between its check and its writes' do
      old_session = child_session
      server.instance_variable_set(:@session, old_session)
      server.instance_variable_set(:@initialized, true)
      claimed = claim_of(server.instance_variable_get(:@transport_generation), old_session)

      at_writes = Queue.new
      release = Queue.new
      allow(server).to receive(:dropped_requests).and_wrap_original do |original, *args|
        at_writes << true
        release.pop
        original.call(*args)
      end

      teardown = Thread.new { server.send(:forget_torn_down_transport, claimed) }
      at_writes.pop

      new_session = child_session
      replacement = Thread.new do
        # What `connect` and the handshake that follows it write.
        server.instance_variable_get(:@transport_lock).synchronize do
          server.instance_variable_set(:@transport_generation, claimed.generation + 1)
        end
        server.instance_variable_set(:@session, new_session)
        server.instance_variable_set(:@initialized, true)
      end

      # The replacement cannot land while the teardown is writing: it takes
      # the same lock, and the teardown holds it across check and writes.
      expect(replacement.join(0.2)).to be_nil

      release << true
      expect(teardown.join(5)).to be_truthy
      expect(replacement.join(5)).to be_truthy

      expect(server.instance_variable_get(:@initialized)).to be(true)
      expect(server.instance_variable_get(:@session)).to equal(new_session)
      expect(server.instance_variable_get(:@transport_generation)).to eq(claimed.generation + 1)
    end

    # The other half of the same rule: when nothing was established since the
    # claim, the teardown still forgets the session and the handshake.
    it 'still forgets the session and the handshake of the process it claimed' do
      old_session = child_session
      server.instance_variable_set(:@session, old_session)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_get(:@awaiting)[7] = true
      claimed = claim_of(server.instance_variable_get(:@transport_generation), old_session)

      server.send(:forget_torn_down_transport, claimed)

      expect(server.instance_variable_get(:@initialized)).to be(false)
      expect(server.instance_variable_get(:@session)).to be_nil
      expect(server.instance_variable_get(:@awaiting)).to be_empty
      expect(server.send(:dropped_requests)).to include(7)
    end
  end

  describe 'the subscriptions a teardown parks' do
    # The listen ids the transport could still cancel for this subscription.
    def outstanding_ids(subscription)
      subscription.instance_variable_get(:@outstanding_listens).map(&:first)
    end

    def subscription_on(generation, id:, io:)
      subscription = MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true })
      subscription.with_open_id(id, generation) { server.send(:register_subscription, subscription) }
      subscription.record_outstanding_listen(id, io)
      subscription.mark_listen_written(id)
      subscription
    end

    # `park_open_subscriptions` drained the whole registry. A subscription the
    # replacement had already opened was parked with the dead process's, its
    # outstanding listen id discarded with them — so `close` had nothing left
    # to cancel and the replacement went on serving a stream this client could
    # no longer name.
    it 'leaves a subscription the replacement opened registered, with its listen still cancellable' do
      generation = server.instance_variable_get(:@transport_generation)
      claimed = claim_of(generation + 1, child_session)
      server.instance_variable_set(:@transport_generation, claimed.generation + 1)

      dead = subscription_on(generation, id: 1, io: StringIO.new)
      live = subscription_on(claimed.generation + 1, id: 2, io: StringIO.new)

      server.send(:park_open_subscriptions, claimed)

      registered = server.send(:subscriptions)
      expect(registered.values).to eq([live])
      expect(outstanding_ids(live)).to eq([2])
      expect(outstanding_ids(dead)).to be_empty
      expect(server.send(:reconnecting_subscriptions)).to eq([dead])
    end

    it 'parks every subscription of the process it claimed' do
      generation = server.instance_variable_get(:@transport_generation)
      claimed = claim_of(generation + 1, child_session)
      server.instance_variable_set(:@transport_generation, claimed.generation)

      first = subscription_on(generation, id: 1, io: StringIO.new)
      second = subscription_on(generation, id: 2, io: StringIO.new)

      server.send(:park_open_subscriptions, claimed)

      expect(server.send(:subscriptions)).to be_empty
      expect(server.send(:reconnecting_subscriptions)).to contain_exactly(first, second)
      expect(outstanding_ids(first)).to be_empty
      expect(outstanding_ids(second)).to be_empty
    end
  end
end
