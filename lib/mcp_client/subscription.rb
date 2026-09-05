# frozen_string_literal: true

require_relative 'subscription/notification_dispatcher'

module MCPClient
  # A long-lived notification subscription opened with `subscriptions/listen`
  # (MCP 2026-07-28 basic/patterns/subscriptions).
  #
  # The subscription is identified by the JSON-RPC id of its listen request;
  # every notification delivered on it carries that id in
  # `_meta["io.modelcontextprotocol/subscriptionId"]`. It starts :pending,
  # becomes :active when the server acknowledges it (with the subset of
  # notification types it agreed to honour), and ends :closed — gracefully
  # when the server answers the listen request, otherwise on a transport
  # drop, a server `notifications/cancelled`, an error, or {#close}.
  class Subscription
    # SubscriptionFilter fields and their value types (taskIds comes from the
    # tasks extension).
    FILTER_FIELDS = {
      'toolsListChanged' => :boolean,
      'promptsListChanged' => :boolean,
      'resourcesListChanged' => :boolean,
      'resourceSubscriptions' => :string_array,
      'taskIds' => :string_array
    }.freeze

    # snake_case spellings accepted for the filter fields
    FILTER_ALIASES = {
      'tools_list_changed' => 'toolsListChanged',
      'prompts_list_changed' => 'promptsListChanged',
      'resources_list_changed' => 'resourcesListChanged',
      'resource_subscriptions' => 'resourceSubscriptions',
      'task_ids' => 'taskIds'
    }.freeze

    STATES = %i[pending active reconnecting closed].freeze

    # Ceiling on the notifications waiting for this subscription's listeners.
    # The queue is filled by the peer and drained by the host, so a chatty
    # server and a listener that does real work (re-reading the resource that
    # changed, say) would otherwise grow it without bound.
    #
    # A full queue discards by identity rather than by arrival order, so
    # overflow costs a listener a repeated notice of the same resource or task
    # and never its only notice of one of them; see
    # {MCPClient::Subscription::NotificationDispatcher} for the policy.
    # Blocking the transport reader instead would reinstate the deadlock the
    # dispatcher exists to prevent — the reader would wait for a listener that
    # is waiting for a response only that reader can deliver.
    MAX_PENDING_NOTIFICATIONS = 1024

    # Ceiling on the bytes the queued notifications retain, because a count is
    # not a memory bound: the method name and params of every queued
    # notification are held until its listener has run, one Streamable HTTP
    # listen event may approach
    # {MCPClient::HttpTransportBase::ListenStream::LISTEN_MAX_BUFFER_BYTES} and
    # a stdio line has no inbound limit at all — so a peer facing a slow
    # listener could put tens of gigabytes behind a nominally bounded queue.
    #
    # This changes when overflow starts, not what it discards: whichever
    # ceiling the arriving notification would breach, the entry that goes is
    # still chosen by identity, and only ever an entry whose removal relieves
    # the breach. A notification larger than the whole budget is not charged
    # against it and is held in a slot of its own, of which there is only ever
    # one — so the retained total is the budget plus at worst one peer-sized
    # payload rather than {MAX_PENDING_NOTIFICATIONS} of them, and no signal
    # is lost to its size or displaced by one.
    MAX_PENDING_NOTIFICATION_BYTES = 8 * 1024 * 1024

    # The states {#wait_until_settled} waits for: the server has answered the
    # listen request one way or the other.
    SETTLED_STATES = %i[active closed].freeze

    # @return [Integer, String, nil] the JSON-RPC id of the listen request (nil before it is sent)
    attr_reader :id
    # @return [Hash] the requested SubscriptionFilter (camelCase keys)
    attr_reader :requested
    # @return [Hash, nil] the filter the server agreed to honour, once acknowledged
    attr_reader :acknowledged
    # @return [MCPClient::ServerBase] the transport that owns the subscription
    attr_reader :server
    # @return [Symbol] :pending, :active, :reconnecting or :closed
    attr_reader :state
    # @return [MCPClient::Errors::MCPError, nil] why the subscription failed, if it did
    attr_reader :error
    # @return [String, nil] the reason a server-side teardown gave, if any
    attr_reader :close_reason

    # Normalize and validate a SubscriptionFilter given with String or Symbol,
    # camelCase or snake_case keys.
    #
    # The result is detached from the caller and frozen. The filter is not
    # serialized once and forgotten: Streamable HTTP builds the listen request
    # on the stream's own thread, after `listen` has returned, and every
    # reconnect builds it again — so an array the caller kept a reference to
    # would let a later `<<` or a mutated String change the request that goes
    # out, or change what a re-opened stream asks for.
    # @param filter [Hash] the notification filter
    # @return [Hash] camelCase String keys, frozen
    # @raise [ArgumentError] on an unknown key or a mistyped value
    def self.normalize_filter(filter)
      raise ArgumentError, 'notifications must be a Hash (SubscriptionFilter)' unless filter.is_a?(Hash)

      filter.to_h do |key, value|
        name = key.to_s
        name = FILTER_ALIASES.fetch(name, name)
        type = FILTER_FIELDS[name]
        raise ArgumentError, "Unknown subscription filter field #{key.inspect}" unless type

        case type
        when :boolean
          raise ArgumentError, "#{name} must be true or false" unless [true, false].include?(value)
        when :string_array
          raise ArgumentError, "#{name} must be an array of strings" unless value.is_a?(Array) && value.all?(String)

          value = value.map { |item| item.dup.freeze }.freeze
        end
        [name, value]
      end.freeze
    end

    # @param server [MCPClient::ServerBase] owning transport
    # @param requested [Hash] normalized filter
    # @yield [method, params] optional listener for notifications on this subscription
    def initialize(server:, requested:, &listener)
      @server = server
      @requested = requested
      @listeners = []
      @listeners << listener if listener
      @state = :pending
      @mutex = Mutex.new
      @settled = ConditionVariable.new
      @id = nil
      @acknowledged = nil
      @error = nil
      @close_reason = nil
      @closed_gracefully = false
      @closed_by_client = false
      @dispatcher = nil
      # Whether the server has answered the listen request this subscription
      # is on — or the last one it was on, while no replacement has gone out.
      # Written where those two things happen ({#acknowledge} and the two
      # methods that take a new listen id), never inferred from how far a
      # transport has got through a reconnect.
      @answered = false
      # Whether a transport is handing this subscription to a new session:
      # see {#reestablishing?}.
      @reestablishing = false
      # The listen ids the transport has written for this subscription on the
      # session it is on, and not yet cancelled: see {#record_outstanding_listen}.
      @outstanding_listens = []
      # Of those, the ones whose write has not finished yet. They are not
      # cancellable: see {#take_outstanding_listens}.
      @unwritten_listens = []
    end

    # @return [Integer] notifications queued for this subscription's listeners
    def pending_notifications
      dispatcher = @mutex.synchronize { @dispatcher }
      dispatcher ? dispatcher.pending : 0
    end

    # Bytes retained by the notifications queued for this subscription's
    # listeners, measured as the JSON the peer sent for them — their method
    # names as well as their params (see {MAX_PENDING_NOTIFICATION_BYTES}).
    # @return [Integer]
    def pending_notification_bytes
      dispatcher = @mutex.synchronize { @dispatcher }
      dispatcher ? dispatcher.pending_bytes : 0
    end

    # Notifications dropped because the listeners could not keep up with the
    # server (see {MAX_PENDING_NOTIFICATIONS} and
    # {MAX_PENDING_NOTIFICATION_BYTES}).
    # @return [Integer]
    def dropped_notifications
      dispatcher = @mutex.synchronize { @dispatcher }
      dispatcher ? dispatcher.dropped : 0
    end

    # Add a listener for notifications delivered on this subscription.
    # @yield [method, params]
    # @return [self]
    def on_notification(&block)
      @mutex.synchronize { @listeners << block }
      self
    end

    # @return [Boolean] whether the server acknowledged it and it is still open
    def active?
      @mutex.synchronize { @state == :active }
    end

    # @return [Boolean]
    def closed?
      @mutex.synchronize { @state == :closed }
    end

    # @return [Boolean] whether it is waiting for a transport to re-establish
    #   it — the stream dropped, or the stdio process it was on exited, and
    #   the transport that noticed has queued it for the next session
    def reconnecting?
      @mutex.synchronize { @state == :reconnecting }
    end

    # @return [Boolean] whether the server ended it with a response to the listen request
    def closed_gracefully?
      @mutex.synchronize { @closed_gracefully }
    end

    # @return [Boolean] whether {#close} ended it
    def closed_by_client?
      @mutex.synchronize { @closed_by_client }
    end

    # Requested notification types the server did not agree to honour.
    #
    # Support is read from the value the server acknowledged, not from the
    # mere presence of the field: an acknowledgment that names
    # `resourceSubscriptions` with none of the URIs it was sent has accepted
    # no resource subscription at all, and a flag acknowledged as `false` will
    # not be honoured either. A list the server granted in part counts as
    # supported; see {#unacknowledged_resource_uris} for the URIs it left out.
    # @return [Array<String>] empty until acknowledged
    def unsupported
      ack = @mutex.synchronize { @acknowledged }
      return [] unless ack

      @requested.keys.reject { |field| granted?(@requested[field], ack[field]) }
    end

    # Requested resource URIs the server did not agree to watch.
    # @return [Array<String>] empty until acknowledged
    def unacknowledged_resource_uris
      ack = @mutex.synchronize { @acknowledged }
      return [] unless ack

      wanted = Array(@requested['resourceSubscriptions'])
      granted = ack['resourceSubscriptions'].is_a?(Array) ? ack['resourceSubscriptions'] : []
      wanted - granted
    end

    # Whether this stream is, right now, an active acknowledged watch of a
    # resource: the server granted that URI and the stream it granted it on is
    # the one still running.
    #
    # Being open is not enough, which is what a `subscribe_resource` looking
    # for a stream to reuse has to know: a stream between listen attempts is
    # serving nothing, and the request that replaces it is a new one the
    # server holds no state for — it may be rejected, or acknowledged more
    # narrowly.
    # @param uri [String] the resource URI
    # @return [Boolean]
    def watching_resource?(uri)
      @mutex.synchronize { @state == :active && acknowledges_resource?(uri) }
    end

    # Block until the server has answered the listen request this subscription
    # is waiting on, and report what it said about this URI.
    #
    # This is the question the subscriber that *opened* the stream asks: it is
    # waiting for the answer to its own listen request, and it gets it. A
    # connection that merely drops does not unask that question and does not
    # unanswer it — the server did grant the filter, and making the caller
    # wait out its whole acknowledgment timeout for an answer it had already
    # been given would be the transport's problem told as the subscriber's. A
    # replacement request that has actually gone out is another matter: the
    # server holds no subscription state across one and has to grant the
    # filter again, so the answer to it is waited for rather than assumed —
    # which is why {#with_open_id} and {#assign_id} unanswer it explicitly,
    # instead of that turning on whether the reconnect has got as far as
    # taking an id.
    #
    # Waiting is also the right answer for a request in flight with nothing
    # granted yet, which used to read as success: a subscription with no
    # acknowledgment has no unacknowledged URIs either.
    # @param uri [String] the resource URI
    # @param timeout [Numeric] seconds to wait for an answer
    # @return [Symbol] :watching, :not_watching (answered without the URI),
    #   :closed, or :timeout
    def await_resource_watch(uri, timeout)
      await_watch(uri, timeout) { @answered }
    end

    # Block until this subscription is a running watch of the URI, and report
    # whether it is.
    #
    # This is the other question, and the one a `subscribe_resource` looking
    # for a stream to *reuse* asks: not "what did the server say" but "is the
    # server watching this, now". Only a running stream answers it. An
    # acknowledgment left on record by a stream that has dropped is not a
    # grant — no server-side subscription exists between listen attempts, the
    # request that replaces it is a new one the server may reject or
    # acknowledge more narrowly, and reading the old record as the current
    # grant reported a watch for the whole of an HTTP backoff or a stdio
    # handshake. So a stream between attempts is waited for instead.
    # @param uri [String] the resource URI
    # @param timeout [Numeric] seconds to wait for the stream to be granted
    # @return [Symbol] :watching, :not_watching (granted without the URI),
    #   :closed, or :timeout
    def await_live_resource_watch(uri, timeout)
      await_watch(uri, timeout) { @state == :active }
    end

    # Block until the server has settled the subscription: acknowledged it,
    # or ended it with a response, an error or a cancellation.
    # @param timeout [Numeric] seconds to wait
    # @return [Symbol, nil] :active or :closed, nil while it is still pending
    def wait_until_settled(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        loop do
          answer = settled_state
          return answer if answer

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if remaining <= 0

          @settled.wait(@mutex, remaining)
        end
      end
    end

    # Cancel the subscription: the transport closes the stream (HTTP) or
    # sends notifications/cancelled (stdio).
    # @return [MCPClient::Subscription, nil] self if it was open, nil if already closed
    def close
      return nil if closed?

      @server.cancel_subscription(self)
      self
    end

    # --- transport-facing state transitions -------------------------------

    # @api private
    def assign_id(id)
      @mutex.synchronize do
        @id = id
        @acknowledged = nil
        # A request the server has not seen is a question it has not answered.
        @answered = false
        # A subscription the host closed stays closed, whatever a racing
        # reconnect does.
        @state = :pending unless @state == :closed
      end
    end

    # Take a fresh listen id and register/send the request under this
    # subscription's own lock, so a concurrent {#close} either wins outright
    # (nothing is sent) or waits and then cancels the id that was sent. A
    # closed subscription is never re-opened.
    # @param id [Integer, String] the new listen request id
    # @yield runs while the id cannot change underneath it
    # @return [Boolean] false when the host had already closed it
    # @api private
    def with_open_id(id)
      @mutex.synchronize do
        return false if @state == :closed

        @id = id
        @acknowledged = nil
        # The request that went out is a new one: whatever the server said
        # about the last, it has not answered this.
        @answered = false
        @state = :pending
        yield
        true
      end
    end

    # Record a listen request the transport has written for this subscription
    # on the session it is on.
    #
    # A cancellation has to name a request the server may be serving, and
    # that is not always the id the subscription happens to be on: a second
    # listen written for it on one session (a hand-over that queued it twice,
    # say) leaves the server holding the first stream, and
    # `notifications/cancelled` for the newest id alone would never close it —
    # the stream stays open until the server's own timeout, with the client
    # unable to name it again.
    #
    # An attempt whose write raised is recorded too: the client cannot know
    # how much of it the peer saw, and cancelling a request the server never
    # received is ignored, while failing to cancel one it did receive is not.
    # Recorded *before* the write for that reason, and marked written by
    # {#mark_listen_written} whichever way the write ends.
    # @param id [Integer, String] the listen request id
    # @return [void]
    # @api private
    def record_outstanding_listen(id)
      @mutex.synchronize do
        @outstanding_listens << id unless @outstanding_listens.include?(id)
        @unwritten_listens << id unless @unwritten_listens.include?(id)
      end
    end

    # The write of a listen request has finished — sent, or raised having sent
    # who knows how much. Either way the id may now be cancelled.
    #
    # An id the session that carried it has since discarded
    # ({#discard_outstanding_listens}) stays discarded: nothing written to a
    # process that is gone is outstanding, and a late write that lands on its
    # closed pipe must not put the id back.
    # @param id [Integer, String] the listen request id
    # @return [void]
    # @api private
    def mark_listen_written(id)
      @mutex.synchronize { @unwritten_listens.delete(id) }
    end

    # The listen ids the server may still be serving for this subscription,
    # leaving none behind: the caller is cancelling them.
    #
    # An id whose write has not finished is not among them, however impatient
    # the caller: "the cancelled request MUST have been previously issued"
    # (basic/patterns/cancellation), and cancelling an id the pipe has not
    # carried yet put `cancelled(n)` on the wire ahead of `listen(n)`. The
    # transport that is writing it cancels it itself once the write is done
    # and it finds the subscription closed — the one moment at which the
    # cancellation can name a request the server has actually been sent.
    # @return [Array] the recorded ids that have been written, oldest first
    # @api private
    def take_outstanding_listens
      @mutex.synchronize do
        taken = @outstanding_listens.reject { |id| @unwritten_listens.include?(id) }
        @outstanding_listens -= taken
        taken
      end
    end

    # Forget the recorded listen ids without cancelling them: the session they
    # were written to is gone, so nothing is outstanding and none of them must
    # be cancelled on the session that replaces it.
    # @return [void]
    # @api private
    def discard_outstanding_listens
      @mutex.synchronize do
        @outstanding_listens = []
        @unwritten_listens = []
      end
    end

    # Whether this subscription is still the stream a given listen id opened.
    # A transport that fails an attempt asks before undoing it: a restart
    # racing a blocked write may already have re-opened the subscription under
    # a newer id, and that stream is not the older attempt's to tear down.
    # @param id [Integer, String] a listen request id
    # @return [Boolean]
    # @api private
    def open_as?(id)
      @mutex.synchronize { @id == id }
    end

    # Record what the server agreed to honour.
    #
    # The filter is copied and frozen through and through, arrays and strings
    # included. The hash it arrives in is the peer's, parsed from the
    # acknowledgment notification, and that same hash is handed to the host's
    # `on_notification` callback and to this subscription's own listeners — so
    # host code that edits it in place would otherwise be rewriting this
    # subscription's record of what the server granted. Adding a URI the
    # acknowledgment left out is enough to make a waiting `subscribe_resource`
    # report a watch that does not exist.
    # @param filter [Hash, nil] the acknowledged SubscriptionFilter
    # @return [void]
    # @api private
    def acknowledge(filter)
      detached = Subscription.deep_frozen_copy(filter.is_a?(Hash) ? filter : {})
      @mutex.synchronize do
        return if @state == :closed

        @acknowledged = detached
        @state = :active
        @answered = true
        # A stream the server has granted is no longer one being handed over.
        @reestablishing = false
        @settled.broadcast
      end
    end

    # A detached, deeply frozen copy of a parsed JSON value.
    # @param value [Object]
    # @return [Object] frozen, sharing nothing mutable with the original
    def self.deep_frozen_copy(value)
      case value
      when Hash then value.to_h { |key, item| [deep_frozen_copy(key), deep_frozen_copy(item)] }.freeze
      when Array then value.map { |item| deep_frozen_copy(item) }.freeze
      when String then value.dup.freeze
      else value
      end
    end

    # @api private
    def deliver(method, params)
      @mutex.synchronize do
        return if @state == :closed || @listeners.empty?

        # Queued while still open, so a closure that follows cannot swallow a
        # notification that had already arrived, and the stop that ends the
        # dispatcher can never overtake this one. Enqueuing never waits for
        # the listeners: the transport reader must stay free to deliver the
        # responses a listener's own requests are waiting for.
        (@dispatcher ||= NotificationDispatcher.new(self)).deliver(@listeners.dup, method, params)
      end
    end

    # @api private
    def mark_reconnecting
      @mutex.synchronize do
        next if @state == :closed

        @state = :reconnecting
        @reestablishing = true
      end
    end

    # Whether a transport is handing this subscription to a new session: it
    # was {#mark_reconnecting}ed and no server has acknowledged it since.
    #
    # Unlike {#reconnecting?} this survives the :pending that taking the new
    # listen id moves it to, which is the whole point: a transport whose
    # re-send fails on the write has to tell a stream it is handing over —
    # which MUST be re-sent, and belongs to the next session — from one it is
    # opening for a caller, which is the caller's to hear about. The state
    # alone cannot: by the time the write raises, the re-send has already
    # moved it off :reconnecting.
    # @return [Boolean]
    # @api private
    def reestablishing?
      @mutex.synchronize { @reestablishing && @state != :closed }
    end

    # @api private
    def finish(gracefully: false, by_client: false, error: nil, reason: nil)
      @mutex.synchronize do
        return if @state == :closed

        @state = :closed
        @closed_gracefully = gracefully
        @closed_by_client = by_client
        @error = error
        @close_reason = reason
        @settled.broadcast
        # Deliveries already queued still run; the dispatcher ends after them.
        @dispatcher&.stop
      end
    end

    # @return [Boolean] whether the subscription should be re-established after a reconnect
    # @api private
    def reconnectable?
      @mutex.synchronize { @state != :closed && !@closed_by_client }
    end

    def inspect
      "#<MCPClient::Subscription id=#{@id.inspect} state=#{@state} requested=#{@requested.keys.join(',')}>"
    end

    private

    # Wait for the condition the caller is asking about to hold, then read the
    # acknowledgment on record for this URI. The block is evaluated with the
    # lock held and decides *when* the record may be read; what it then says
    # about the URI is the same question either way.
    # @param uri [String] the resource URI
    # @param timeout [Numeric] seconds to wait
    # @yieldreturn [Boolean] whether the record may be read yet
    # @return [Symbol] :watching, :not_watching, :closed or :timeout
    def await_watch(uri, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        loop do
          return :closed if @state == :closed
          return acknowledges_resource?(uri) ? :watching : :not_watching if yield

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return :timeout if remaining <= 0

          @settled.wait(@mutex, remaining)
        end
      end
    end

    # Whether the value the server acknowledged for a requested field grants
    # anything: a flag has to come back true, and a list of URIs or task ids
    # has to name at least one of those asked for. Anything else is the server
    # declining the field while echoing its name. A field this client did not
    # really ask for (a `false` flag, an empty list) is trivially granted —
    # there was nothing there for the server to decline.
    # @param wanted [Object] the value this client asked for
    # @param granted [Object] the value the server acknowledged
    # @return [Boolean]
    def granted?(wanted, granted)
      if wanted.is_a?(Array)
        return true if wanted.empty?

        return granted.is_a?(Array) && wanted.intersect?(granted)
      end

      wanted == false || granted == true
    end

    # Whether the acknowledgment that stands names this URI. Called with the
    # lock held.
    # @param uri [String] the resource URI
    # @return [Boolean]
    def acknowledges_resource?(uri)
      granted = @acknowledged.is_a?(Hash) ? @acknowledged['resourceSubscriptions'] : nil
      granted.is_a?(Array) && granted.include?(uri)
    end

    # The answer {#wait_until_settled} reports. A drop does not unask the
    # question the waiter asked: the server acknowledged the listen request,
    # and putting the stream back to :reconnecting until it is acknowledged
    # again does not unanswer it. A replacement request that has gone out
    # does — that one is unanswered until the server answers it, which is a
    # different thing from a connection that merely dropped and is recorded
    # as such rather than left to whichever the reconnect reached first.
    # Called with the lock held.
    # @return [Symbol, nil] :closed, :active, or nil while it is still pending
    def settled_state
      return @state if SETTLED_STATES.include?(@state)
      return :active if @answered

      nil
    end
  end
end
