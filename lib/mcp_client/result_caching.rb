# frozen_string_literal: true

require 'digest'

require_relative 'cached_result'

module MCPClient
  # Freshness bookkeeping for cacheable results (MCP 2026-07-28
  # server/utilities/caching), shared by every transport: hints recorded per
  # operation (:discover, :tools, :prompts, :resources, :templates and
  # per-URI reads), freshness checks, invalidation on change notifications,
  # and the rule that multi round-trip retry results are never cached.
  module ResultCaching
    # Operation kinds with a list cache and the notification that invalidates them.
    LIST_CHANGE_NOTIFICATIONS = {
      'notifications/tools/list_changed' => %i[tools],
      'notifications/prompts/list_changed' => %i[prompts],
      # resources/list_changed also covers resources/templates/list.
      'notifications/resources/list_changed' => %i[resources templates]
    }.freeze

    # Guards the lazy creation of the per-transport cache structures, which
    # request threads and notification threads may touch first.
    CACHE_INIT_LOCK = Mutex.new

    # Kinds whose cached list lives in the entry itself: a hint recorded for
    # one of them without its list (the list is still being converted, or
    # its conversion failed) is not a cache that may be served.
    LIST_VALUE_KINDS = %i[tools prompts resources templates].freeze

    # Every list kind that gets a stale placeholder when the cache is
    # cleared, recorded or not, so a copy stored while the clear happened is
    # never served as an unhinted (legacy) list.
    PLACEHOLDER_KINDS = %i[tools prompts resources templates].freeze

    # The served-entry identity of a list that carried no cache hint at all
    # (a legacy server): nothing was recorded, and nothing was rejected.
    LEGACY_ENTRY = :legacy

    # How many resources/read results are kept at once: iterating many
    # resources must not grow memory with every URI ever read.
    MAX_CACHED_READS = 64

    # How many per-URI invalidation generations are kept: a server varying
    # the URI of notifications/resources/updated cannot grow the map without
    # bound — past this, every read counts as invalidated at once instead.
    MAX_READ_GENERATIONS = 256

    # Paginated list methods and their cache kind.
    LIST_METHOD_KINDS = {
      'tools/list' => :tools,
      'prompts/list' => :prompts,
      'resources/list' => :resources,
      'resources/templates/list' => :templates
    }.freeze

    # @return [Float] monotonic clock, in seconds (stubbed in tests)
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Transports note the moment a response's bytes were in hand, before the
    # notifications it carried are dispatched (a callback may run long, or
    # send a nested request on this thread): the TTL runs from receipt (MCP
    # 2026-07-28 caching, "Freshness Calculation"), not from the end of that
    # processing. The value is per thread and per transport, consumed once.
    # @param now [Float] the monotonic receipt time
    # @return [void]
    def note_response_received_at(now = monotonic_now)
      Thread.current[response_received_key] = now
    end

    # Forget a receipt time a request path is about to replace.
    # @return [void]
    def clear_response_received_at
      Thread.current[response_received_key] = nil
    end

    # The receipt time of the response this thread just got, or the current
    # time when none was noted (a stubbed transport) or the noted one is older
    # than the request that asks (a leftover from an earlier request).
    # @param since [Float, nil] when the consuming request started
    # @return [Float]
    def response_received_at(since: nil)
      noted = Thread.current[response_received_key]
      Thread.current[response_received_key] = nil
      return monotonic_now unless noted
      return monotonic_now if since && noted < since

      noted
    end

    # @return [Symbol] this transport's thread-local key for the receipt time
    def response_received_key
      :"mcp_response_received_at_#{object_id}"
    end

    # @return [Hash{Object => MCPClient::CachedResult}]
    def cache_entries
      @cache_entries || CACHE_INIT_LOCK.synchronize { @cache_entries ||= {} }
    end

    # @return [Mutex]
    def cache_entries_mutex
      @cache_entries_mutex || CACHE_INIT_LOCK.synchronize { @cache_entries_mutex ||= Mutex.new }
    end

    # The invalidation generation of one cache key, so a response that was
    # in flight while its own entry was invalidated is not written back —
    # while an invalidation of another key (a resource updated during a
    # tools/list) leaves it alone. Every key shares a base bumped when the
    # whole cache goes (cleanup, a new authorization context); each key keeps
    # its own count, and every read shares one more.
    #
    # The three are compared side by side rather than added up: a cleanup
    # bumps the base *and* clears the other counts, so a sum would carry a
    # key an invalidation had already bumped (0 + 1) straight through the
    # cleanup unchanged (1 + 0), and the response of a request the cleanup
    # overtook would install itself as fresh.
    # @param key [Symbol, String, nil] the cache key; nil for the base alone
    # @return [Array<Integer>] an identity, only ever compared for equality
    def cache_epoch(key = nil)
      cache_entries_mutex.synchronize { cache_generation(key) }
    end

    # @param method [String] a list method, e.g. 'tools/list'
    # @return [Array<Integer>] the generation of that list's cache key
    def list_cache_epoch(method)
      cache_epoch(list_kind_for(method))
    end

    # @param method [String] a list method, e.g. 'tools/list'
    # @return [Symbol, nil] the cache kind that list fills
    def list_kind_for(method)
      LIST_METHOD_KINDS[method]
    end

    # @return [Array<Integer>] (call while holding cache_entries_mutex)
    def cache_generation(key)
      base = @cache_epoch || 0
      return [base] if key.nil?

      gens = @cache_generations || {}
      own = gens[key] || 0
      reads = key.is_a?(String) && key.start_with?('read:') ? (gens[:'read:*'] || 0) : 0
      [base, own, reads]
    end

    # @return [void] (call while holding cache_entries_mutex)
    def bump_cache_epoch
      @cache_epoch = (@cache_epoch || 0) + 1
      # Every key's generation moved with the base: the per-key counts have
      # nothing left to add.
      @cache_generations = nil
    end

    # @param key [Symbol, String] a cache key, or :'read:*' for every read
    # @return [void] (call while holding cache_entries_mutex)
    def bump_cache_generation(key)
      @cache_generations ||= {}
      @cache_generations[key] = (@cache_generations[key] || 0) + 1
      return unless key.is_a?(String) && @cache_generations.count { |k, _| k.is_a?(String) } > MAX_READ_GENERATIONS

      # Too many URIs to remember one by one: fold them into the count that
      # invalidates every read. The shared count jumps past the largest
      # per-URI count it absorbs, so no key's generation stands still or
      # goes back — a read still in flight cannot be stored against a
      # generation this fold already left behind.
      absorbed = @cache_generations.select { |k, _| k.is_a?(String) }.values.max || 0
      @cache_generations.delete_if { |k, _| k.is_a?(String) }
      @cache_generations[:'read:*'] = (@cache_generations[:'read:*'] || 0) + absorbed + 1
    end

    # Record the freshness hint of one result.
    # @param kind [Symbol, String] :tools, :prompts, :resources, :templates, :discover or "read:<uri>"
    # @param result [Hash] the CacheableResult
    # @param value [Object] what the cache holds for this kind (may be nil: hint only)
    # @return [MCPClient::CachedResult]
    # @param epoch [Integer, nil] the cache epoch captured before the request went out: a result
    #   whose entry was invalidated meanwhile is recorded as stale, not as fresh
    def record_cache_hint(kind, result, value = nil, epoch: nil, received_at: nil)
      now = received_at || response_received_at
      entry = cache_entry_for(result, value, now: now)
      cache_entries_mutex.synchronize do
        if epoch && epoch != cache_generation(kind)
          # Invalidated while in flight: whatever is installed now (the
          # invalidation's placeholder, or a newer fetch) stays; this result
          # is reported stale and never stored.
          entry = MCPClient::CachedResult.stale(now: now, like: entry)
        else
          cache_entries[kind] = entry
        end
      end
      remember_recorded_entry(kind, entry)
    end

    # Build the entry for one result: an absent ttlMs counts as 0 on a
    # 2026-07-28 server, and the entry remembers the authorization context
    # of the request that produced it (transports that know it).
    # @return [MCPClient::CachedResult]
    def cache_entry_for(result, value, now:)
      entry = MCPClient::CachedResult.from_result(result, value, now: now, assume_zero: assume_zero_ttl?)
      bind_authorization_context(entry)
    end

    # @param entry [MCPClient::CachedResult]
    # @return [MCPClient::CachedResult] the same entry, bound to the current request's context
    def bind_authorization_context(entry)
      entry.authorization_context = request_authorization_context if respond_to?(:request_authorization_context, true)
      entry.params_fingerprint = request_params_fingerprint if respond_to?(:request_params_fingerprint, true)
      entry
    end

    # @return [Boolean] whether an absent ttlMs means "immediately stale" (2026-07-28 servers)
    def assume_zero_ttl?
      respond_to?(:modern?) && modern?
    end

    # Record the hint of an auto-paginated list from its pages (shortest TTL wins).
    # @param kind [Symbol] the list kind
    # @param page_results [Array<Hash>] the per-page results
    # @param value [Object] what the cache holds (may be nil)
    # @return [MCPClient::CachedResult, nil]
    # @param received_ats [Array<Float>, nil] each page's monotonic receipt time (defaults to now)
    # @param contexts [Array<String, nil>, nil] each page's request authorization context
    # @param epoch [Integer, nil] the cache epoch when the first page was requested
    def record_paginated_cache_hint(kind, page_results, value = nil, received_ats: nil, contexts: nil, params: nil,
                                    epoch: nil)
      now = monotonic_now
      entries = page_results.each_with_index.map do |result, index|
        # A bare array page (accepted for compatibility) carries no hint:
        # on a modern server that means ttlMs 0.
        MCPClient::CachedResult.from_result(result.is_a?(Hash) ? result : {}, nil,
                                            now: (received_ats && received_ats[index]) || now,
                                            assume_zero: assume_zero_ttl?)
      end
      return nil if entries.empty?

      combined = bind_authorization_context(MCPClient::CachedResult.combine(entries, value, now: now))
      # A list invalidated while it was being fetched is already stale and
      # never replaces what is installed now (the invalidation's placeholder
      # or a newer fetch); a private list whose pages were fetched under
      # different credentials belongs to no single context, and a list whose
      # pages were fetched under differing effective parameters (the host's
      # request_meta changed between pages) matches no request's parameters,
      # whatever its scope.
      combined = mixed_pages_placeholder(combined, now, contexts: contexts, params: params)
      cache_entries_mutex.synchronize do
        if epoch && epoch != cache_generation(kind)
          combined = MCPClient::CachedResult.stale(now: now, like: combined)
        else
          cache_entries[kind] = combined
        end
      end
      remember_recorded_entry(kind, combined)
    end

    # The entry to record for a combined list: the list itself, or — when
    # its pages were fetched under differing credentials (a private list)
    # or differing effective parameters (any list) — a stale placeholder
    # that no context or parameters match.
    # @param combined [MCPClient::CachedResult]
    # @param now [Float]
    # @param contexts [Array, nil] the pages' authorization contexts
    # @param params [Array, nil] the pages' params fingerprints
    # @return [MCPClient::CachedResult]
    def mixed_pages_placeholder(combined, now, contexts:, params:)
      mixed = combined.cache_scope == 'private' && contexts && contexts.uniq.size > 1
      mixed_params = params && params.uniq.size > 1
      return combined unless mixed || mixed_params

      placeholder = MCPClient::CachedResult.stale(now: now, like: combined)
      placeholder.authorization_context = MCPClient::CachedResult::MIXED_CONTEXT if mixed
      placeholder.params_fingerprint = MCPClient::CachedResult::MIXED_PARAMS if mixed_params
      placeholder
    end

    # Stamp the entry this thread's fetch recorded with a fresh identity and
    # remember it, so the list the same fetch converts afterwards can be
    # attached to its own entry and to no other (the thread keeps only the
    # bare identity, never the entry or its list).
    # @param kind [Symbol]
    # @param entry [MCPClient::CachedResult]
    # @return [MCPClient::CachedResult] the entry
    def remember_recorded_entry(kind, entry)
      entry.fetch_token = Object.new
      # Only a list attaches its value afterwards and takes its identity
      # back out again: remembering any other kind (a discovery, which is
      # never attached) would leave a token on the thread for the life of
      # the thread, one per transport a long-lived worker ever built.
      return entry unless LIST_VALUE_KINDS.include?(kind)

      (Thread.current[recorded_entries_key] ||= {})[kind] = entry.fetch_token
      entry
    end

    # @return [Symbol] the thread-local key of this server's recorded entries
    def recorded_entries_key
      :"mcp_client_recorded_entries_#{object_id}"
    end

    # Remember, per thread, the entry a list of a kind was last served or
    # attached from — its identity and the parameters it is bound to — so a
    # cache built on top (the client's) can tie its slice to that very entry.
    # @param kind [Symbol]
    # @param entry [MCPClient::CachedResult, nil] the entry (nil: none)
    # @return [void]
    def note_served_entry(kind, entry)
      (Thread.current[served_entries_key] ||= {})[kind] = entry && [entry.fetch_token, entry.params_fingerprint]
    end

    # Note that this thread's last list of a kind carried no hint at all.
    # @param kind [Symbol]
    # @return [Symbol] LEGACY_ENTRY
    def note_legacy_served(kind)
      (Thread.current[served_entries_key] ||= {})[kind] = [LEGACY_ENTRY, nil]
      LEGACY_ENTRY
    end

    # Take the note left for a kind: it is written for the one cache above
    # this transport that tags its slice with it, so reading it consumes it.
    # The slot itself goes once nothing is left in it, rather than staying on
    # the thread for the life of a worker that lists through many transports.
    # @param kind [Symbol]
    # @return [Array(Object, String), nil] the identity of the entry this
    #   thread's last list of the kind came from and the parameters
    #   fingerprint it is bound to
    def take_served_entry(kind)
      notes = Thread.current[served_entries_key]
      return nil if notes.nil?

      note = notes.delete(kind)
      Thread.current[served_entries_key] = nil if notes.empty?
      note
    end

    # Drop every note this thread holds for this transport (its connection
    # is going away, so nothing will tag a slice with them).
    # @return [void]
    def forget_served_entries
      Thread.current[served_entries_key] = nil
    end

    # The thread-local slots a transport owns, each keyed by its own
    # `object_id`: the notes of the entries it served and recorded, the
    # receipt time, the credentials and effective parameters of the request
    # this thread last sent through it, and its multi round-trip marker.
    #
    # The evaluation an open operation reserved for its own request is
    # deliberately not among them: a reconnect tears the connection down
    # (`ensure_connected` cleans up before it connects) in the middle of the
    # very request a cache decision reserved it for, and that request must
    # still carry it. The reservation belongs to the operation, which drops
    # it when it ends ({MCPClient::RequestMetaScope}).
    # @return [Array<Symbol>] the keys defined on this transport
    def transport_thread_local_keys
      %i[served_entries_key recorded_entries_key response_received_key
         request_params_key round_trip_marker_key request_authorization_key
         called_tool_definition_key]
        .select { |name| respond_to?(name, true) }
        .map { |name| send(name) }
    end

    # Drop everything this transport left on the calling thread: its
    # connection is going away, so none of it describes a request that will
    # ever be made or a slice that will ever be tagged. A worker thread that
    # creates and discards transports would otherwise accumulate one entry
    # per slot per transport for its whole life.
    # @return [void]
    def forget_transport_thread_state
      transport_thread_local_keys.each { |key| Thread.current[key] = nil }
    end

    # @param kind [Symbol]
    # @return [Object, nil] the identity of the entry currently holding the kind
    # Whether the entry a client-level slice came from is still fresh by its
    # own hint — a lock-safe re-check (no probe, no host callable) for the
    # moment a snapshot is handed out. No entry means nothing bounds it.
    # @param kind [Symbol]
    # @return [Boolean]
    def cache_entry_fresh?(kind)
      cache_entries_mutex.synchronize do
        entry = cache_entries[kind]
        entry.nil? || (!entry.value.nil? && entry.fresh?(now: monotonic_now))
      end
    end

    # Whether the entry holding a kind bounds its own freshness: a server
    # that sent a ttlMs (or a 2026-07-28 server whose absent ttlMs means 0)
    # says how long its list may be kept, empty or not. Without a hint the
    # client's own heuristic applies instead, and an empty list is asked for
    # again rather than kept for the life of the connection.
    # @param kind [Symbol]
    # @return [Boolean]
    def cache_entry_hinted?(kind)
      cache_entries_mutex.synchronize do
        entry = cache_entries[kind]
        !entry.nil? && !entry.value.nil? && entry.hint?
      end
    end

    def cache_entry_token(kind)
      # A placeholder (an invalidation, a cleanup) identifies nothing.
      cache_entries_mutex.synchronize do
        entry = cache_entries[kind]
        entry&.value.nil? ? nil : entry.fetch_token
      end
    end

    # @return [Symbol] the thread-local key of this server's served entries
    def served_entries_key
      :"mcp_client_served_entries_#{object_id}"
    end

    # Called by the paginated list helper with the raw page results.
    # @param method [String] the list method
    # @param page_results [Array<Hash>]
    # @return [void]
    # @param received_ats [Array<Float>, nil] each page's monotonic receipt time
    # @param contexts [Array<String, nil>, nil] each page's request authorization context
    # @param epoch [Integer, nil] the cache epoch when the first page was requested
    def record_list_cache_hint(method, page_results, received_ats = nil, contexts: nil, params: nil, epoch: nil)
      kind = LIST_METHOD_KINDS[method]
      return unless kind

      record_paginated_cache_hint(kind, page_results, received_ats: received_ats, contexts: contexts, params: params,
                                                      epoch: epoch)
    end

    # Whether the cached response for a kind may still be served. No entry
    # (nothing cached yet) or no hint (older server) means the client's own
    # heuristic applies: cache until a change notification.
    # @param kind [Symbol, String]
    # @return [Boolean]
    def cache_fresh?(kind)
      entry = private_entry_for_current_context(kind)
      return true if entry.nil?
      return false if LIST_VALUE_KINDS.include?(kind) && entry.value.nil?

      entry.fresh?(now: monotonic_now)
    end

    # The list a transport with no cache of its own may serve for a kind:
    # only one the server itself bounded ("If ttlMs is positive, the client
    # SHOULD consider the result fresh for that many milliseconds"). A list
    # without a hint is left to the client's own cache, which asks again for
    # an empty one instead of keeping it for the life of the connection.
    # @param kind [Symbol]
    # @return [Object, nil]
    def hinted_list_value(kind)
      cache_entry_hinted?(kind) ? fresh_list_value(kind) : nil
    end

    # The list a transport may serve for a kind without fetching: the value
    # of a fresh entry in the current authorization context. With no entry
    # at all (nothing recorded yet) the transport's own copy, given by the
    # block, stands in; a hint without a value never lets that copy through.
    # @param kind [Symbol]
    # @yield the transport's own copy of the list
    # @return [Object, nil]
    def fresh_list_value(kind)
      entry = private_entry_for_current_context(kind)
      if entry.nil?
        note_legacy_served(kind)
        return block_given? ? yield : nil
      end
      # An invalidation (a list_changed notification, a cleanup) that lands
      # after the lookup — the authorization probe makes that a wide window —
      # replaces the slot but leaves this reference intact: the copy is made
      # under the lock, and only while the entry is still the one the map
      # holds and still fresh.
      copy = cache_entries_mutex.synchronize do
        next nil unless cache_entries[kind].equal?(entry) && entry.value && entry.fresh?(now: monotonic_now)

        MCPClient::DeepCopy.copy(entry.value)
      end
      return nil unless copy

      release_serving_request_meta
      note_served_entry(kind, entry)
      copy
    end

    # The list recorded for a kind whatever its freshness: the candidate for
    # serving stale when a re-fetch fails ({#stale_fallback_for} decides).
    # @param kind [Symbol]
    # @return [Object, nil]
    def stale_list_value(kind)
      cache_entries_mutex.synchronize { cache_entries[kind]&.value }
    end

    # The entry whose (possibly stale) list may be served when a re-fetch
    # fails; the entry itself, so the fallback is judged by the entry that
    # supplied the value and not by whatever entry is installed by then.
    # @param kind [Symbol]
    # @return [MCPClient::CachedResult, nil]
    def stale_list_entry(kind)
      cache_entries_mutex.synchronize { cache_entries[kind] }
    end

    # The entry for a kind, after making sure a privately scoped one still
    # belongs to the current authorization context (transports that know
    # their context re-check it here; a changed context drops the entry).
    # @param kind [Symbol, String]
    # @return [MCPClient::CachedResult, nil]
    def private_entry_for_current_context(kind)
      entry = cache_entries_mutex.synchronize { cache_entries[kind] }
      return entry if entry_in_current_context?(entry, kind: kind)

      # Another context's private entry reads as known-and-stale, never as
      # "nothing cached" (which would count as fresh) and never as a value.
      MCPClient::CachedResult.stale(now: monotonic_now)
    end

    # @param entry [MCPClient::CachedResult, nil]
    # @return [Boolean] whether the entry may be served in the current authorization context
    # @param context [String, nil, :current, :unknown] the authorization context to check against
    #   (:current asks the transport which credentials it would send now for the operation of
    #   `kind`; :unknown means the credentials are not known, so no private entry matches)
    # @param kind [Symbol, String, nil] the cache kind, so the transport models the request of
    #   that very operation (middleware may pick credentials by method or body)
    def entry_in_current_context?(entry, context: :current, kind: nil)
      return false if entry && !entry_for_current_params?(entry, context)

      # The metadata this lookup evaluated stays held: an entry that belongs
      # to the context may still be too stale to serve, and the request that
      # then goes out carries the very evaluation the decision was made on.
      # {#release_serving_request_meta} drops it once a value really is
      # served instead.
      entry_matches_authorization?(entry, context, kind)
    rescue StandardError
      # The lookup aborted — the authorization probe raised, an OAuth
      # refresh failed — so it builds no request at all. Whatever evaluation
      # of the host's request_meta it was holding for that request would
      # otherwise sit on this thread and be sent, much later, by an
      # unrelated request: the next request reads the host afresh instead.
      release_serving_request_meta
      raise
    end

    # A cached value was served, so the lookup that led here leads to no
    # request of its own: the metadata held for that request is dropped
    # rather than sent, some time later, by another one.
    # @return [void]
    def release_serving_request_meta
      release_held_request_meta if respond_to?(:release_held_request_meta, true)
    end

    # @param entry [MCPClient::CachedResult, nil]
    # @param context [String, nil, :current, :unknown]
    # @param kind [Symbol, String, nil]
    # @return [Boolean] whether a privately scoped entry belongs to the context being served
    def entry_matches_authorization?(entry, context, kind)
      return true unless entry&.cache_scope == 'private' && respond_to?(:current_authorization_context, true)
      return false if entry.authorization_context.equal?(MCPClient::CachedResult::MIXED_CONTEXT)

      context = current_authorization_context(kind) if context == :current
      entry.authorization_context == context
    end

    # Whether an entry was produced by a request carrying the effective
    # parameters (host `_meta`) the request being served would carry: the
    # next request's for a :current lookup, the failed attempt's own when a
    # stale fallback is judged. A result is never served across them,
    # whatever its scope.
    # @param entry [MCPClient::CachedResult]
    # @param context [String, nil, :current, :unknown]
    # @return [Boolean]
    def entry_for_current_params?(entry, context)
      return false if entry.params_fingerprint.equal?(MCPClient::CachedResult::MIXED_PARAMS)
      return true unless entry.params_fingerprint && respond_to?(:current_params_fingerprint, true)

      expected = context == :current ? current_params_fingerprint : request_params_fingerprint
      # A failed attempt that never built its request noted no parameters:
      # it matches no entry, whatever the previous request on this thread
      # carried.
      # Reading the next request's parameters evaluates a host request_meta
      # callable, and the transport holds that evaluation for the request
      # this lookup leads to (or for the probe that models it); the caller
      # drops it once the entry is served instead.
      expected.is_a?(String) && entry.params_fingerprint == expected
    end

    # Attach the list a request produced to the very entry that request
    # recorded (the one this thread's fetch created, or the one passed in),
    # so a value can never land on another request's TTL, scope or
    # authorization context: when a later fetch has replaced the entry the
    # value is dropped and the later fetch wins.
    # @param kind [Symbol]
    # @param value [Object] the list objects
    # @param entry [MCPClient::CachedResult, nil] the entry the fetch recorded
    #   (defaults to the one recorded on this thread)
    # @return [Boolean] whether the value was attached
    def attach_list_value(kind, value, entry: nil)
      recorded = Thread.current[recorded_entries_key]
      token = entry ? entry.fetch_token : recorded&.delete(kind)
      # Nothing of this transport's is outstanding on this thread any more.
      Thread.current[recorded_entries_key] = nil if recorded && recorded.empty?
      note_served_entry(kind, nil)
      # Nothing recorded for this fetch: a legacy list without a hint, which
      # the transport keeps until a list_changed notification. A recorded
      # hint whose entry is gone or replaced is a rejection (false).
      return note_legacy_served(kind) unless token

      context = respond_to?(:request_authorization_context, true) ? request_authorization_context : nil
      cache_entries_mutex.synchronize do
        entry = cache_entries[kind]
        return false unless entry && entry.fetch_token.equal?(token)
        return false if entry.cache_scope == 'private' && entry.authorization_context != context

        # The cache keeps its own copy: what the fetch returns to its caller
        # may be changed freely.
        entry.value = MCPClient::DeepCopy.copy(value)
        note_served_entry(kind, entry)
        true
      end
    end

    # The cached list for a kind, when its entry is fresh and belongs to
    # the current authorization context.
    # @param kind [Symbol]
    # @return [Object, nil]
    def cached_list_value(kind)
      entry = private_entry_for_current_context(kind)
      return nil unless entry&.value && entry.fresh?(now: monotonic_now)

      release_serving_request_meta
      entry.value
    end

    # The stale copy that may be served when a re-fetch fails: the value of
    # the entry captured before the re-fetch, and only when that very entry
    # belongs to the authorization context (checked against the credentials
    # the failed request actually used, when the caller knows them) — an
    # entry installed meanwhile by another request never vouches for it.
    # @param kind [Symbol]
    # @param entry [MCPClient::CachedResult, nil] the entry captured before the re-fetch
    # @param context [String, nil, :current] the authorization context to check against
    # @return [Object, nil]
    def stale_fallback_for(kind, entry, context: :current)
      return nil unless entry.is_a?(MCPClient::CachedResult) && entry.value
      # An entry a cleanup or an invalidation replaced while the re-fetch
      # was in flight is forgotten: only the entry still in the slot serves.
      return nil unless cache_entries_mutex.synchronize { cache_entries[kind].equal?(entry) }

      note_served_entry(kind, entry)
      return nil unless entry_in_current_context?(entry, context: context, kind: kind)

      # Judging the context runs the probe, and an invalidation may land
      # while it does: the copy is taken under the lock, and only while the
      # entry is still the one the map holds.
      cache_entries_mutex.synchronize do
        next nil unless cache_entries[kind].equal?(entry) && entry.value

        MCPClient::DeepCopy.copy(entry.value)
      end
    end

    # The freshness hint recorded for an operation.
    # @param kind [Symbol] :discover, :tools, :prompts, :resources, :templates or :read
    # @param key [String, nil] the resource URI for :read
    # @return [Hash, nil] ttl_ms, cache_scope, received_at, fresh — nil when nothing was recorded
    def cache_info(kind, key = nil)
      entry = cache_entries_mutex.synchronize { cache_entries[kind == :read ? read_cache_key(key) : kind] }
      entry&.to_info(now: monotonic_now)
    end

    # Mark a kind stale: a change notification invalidates a still-fresh
    # cache, so the kind must read as stale (not as "nothing known", which
    # would let a concurrently snapshotted list be served) until the next
    # fetch records a new hint.
    # @param kind [Symbol, String]
    # @return [void]
    def invalidate_cache(kind)
      now = monotonic_now
      cache_entries_mutex.synchronize do
        cache_entries[kind] = MCPClient::CachedResult.stale(now: now, like: cache_entries[kind])
        bump_cache_generation(kind)
      end
    end

    # The JSON-RPC code a server answers a cursor it no longer accepts with
    # (MCP pagination: an invalid cursor SHOULD be an -32602 Invalid params).
    # @param error [Exception] the failure a page request raised
    # @return [Boolean]
    def invalid_cursor_error?(error)
      error.is_a?(MCPClient::Errors::ServerError) && error.code == MCPClient::Errors::Codes::INVALID_PARAMS
    end

    # Run one page request of a paginated list, dropping the pages cached for
    # that list when the server rejects the cursor it carried. A cursor names
    # a position in one sequence of pages: once the server has forgotten it,
    # the first page cached from that sequence is gone with it, and serving
    # that page again would hand the caller the same dead cursor to follow.
    # A rejection of the *first* page's request carries no cursor and says
    # nothing about the cache, so it leaves it alone.
    # @param kind [Symbol, nil] the list kind
    # @param cursor [String, nil] the cursor this page request carries
    # @yield sends the page request
    # @return [Object] the block's value
    def fetching_list_page(kind, cursor)
      yield
    rescue MCPClient::Errors::ServerError => e
      raise unless kind && cursor && invalid_cursor_error?(e)

      discard_paginated_list(kind)
      raise
    end

    # Forget everything cached for a paginated list: the entry that bounds it
    # and the transport's own copy, so the next access really re-fetches from
    # the first page.
    # @param kind [Symbol] the list kind
    # @return [void]
    def discard_paginated_list(kind)
      invalidate_cache(kind)
      invalidate_list_cache(kind) if respond_to?(:invalidate_list_cache, true)
    end

    # Forget every cached result and hint (the connection, and with it the
    # authorization context, is gone).
    # @return [void]
    def clear_result_cache
      now = monotonic_now
      cache_entries_mutex.synchronize do
        # Lists stay known-and-stale (a client-level cache built from the old
        # connection must not read an empty entry as "fresh"); reads are
        # simply forgotten, they are only ever served with a value.
        cache_entries.delete_if { |key, _| key.is_a?(String) }
        PLACEHOLDER_KINDS.each { |kind| cache_entries[kind] ||= nil }
        cache_entries.each_key do |key|
          # Whoever still holds the replaced object (a re-fetch in flight)
          # must not serve its list either.
          cache_entries[key]&.value = nil
          cache_entries[key] = MCPClient::CachedResult.stale(now: now, like: cache_entries[key])
        end
        bump_cache_epoch
      end
    end

    # The Authorization value in a header collection, whatever the key's
    # spelling: HTTP field names are case-insensitive and hosts configure
    # them as strings or symbols (`Authorization:`, 'AUTHORIZATION').
    # @param headers [Hash, #[], nil]
    # @return [String, nil]
    def authorization_header_value(headers)
      MCPClient::ResultCaching.authorization_header_value(headers)
    end

    # @see #authorization_header_value (usable from middleware classes too)
    # @param headers [Hash, #[], nil]
    # @return [String, nil]
    def self.authorization_header_value(headers)
      return nil if headers.nil?
      # Faraday's own table already holds one entry per field name.
      return headers['Authorization'] if headers.is_a?(Faraday::Utils::Headers)
      return headers['Authorization'] || headers['authorization'] unless headers.respond_to?(:each_pair)

      # A plain Hash can hold several spellings at once (a configured
      # `authorization:` and an OAuth provider's canonical `Authorization`).
      # Faraday copies them into a case-insensitive table, so the request
      # carries what the last of them writes — and so must the fingerprint.
      value = nil
      headers.each_pair { |key, header| value = header if key.to_s.casecmp?('authorization') }
      value
    end

    # The header table a Faraday request built from these headers carries:
    # field names are case-insensitive there, so several spellings of one
    # header collapse into a single entry and a later write of any spelling
    # (an OAuth provider's canonical `Authorization`) replaces it rather
    # than leaving the older one behind.
    #
    # The table is always a detached copy: its caller hands it to the OAuth
    # provider, which writes the Authorization it would apply into it, and
    # that must never reach the headers the transport builds its requests
    # from (a probed token would outlive the credentials it came from).
    # @param headers [Hash, #each_pair, nil]
    # @return [Faraday::Utils::Headers]
    def self.faraday_headers(headers)
      # Faraday's own table dups its case-insensitive name index with it.
      return headers.dup if headers.is_a?(Faraday::Utils::Headers)
      return Faraday::Utils::Headers.new unless headers.respond_to?(:each_pair)

      Faraday::Utils::Headers.new(headers.to_h)
    end

    # @see .faraday_headers
    # @param headers [Hash, #each_pair, nil]
    # @return [Faraday::Utils::Headers]
    def faraday_headers(headers)
      MCPClient::ResultCaching.faraday_headers(headers)
    end

    # A stable, non-reversible identifier of an Authorization header, so a
    # cache entry can be bound to the credentials that produced it without
    # keeping the credentials themselves around.
    # @param header [String, nil]
    # @return [String, nil]
    def authorization_fingerprint(header)
      return nil if header.nil?

      Digest::SHA256.hexdigest(header.to_s)
    end

    # Forget the entries cached under `cacheScope: "private"`: they "MUST NOT
    # be shared across authorization contexts" (a new access token is one).
    # @return [void]
    def invalidate_private_cache
      now = monotonic_now
      cache_entries_mutex.synchronize do
        cache_entries.each_key do |key|
          next unless cache_entries[key].cache_scope == 'private'

          cache_entries[key] = MCPClient::CachedResult.stale(now: now, like: cache_entries[key])
        end
        bump_cache_epoch
      end
    end

    # Forget cached resources/read results: one URI, or all of them.
    # @param uri [String, nil]
    # @return [void]
    def invalidate_read_cache(uri = nil)
      cache_entries_mutex.synchronize do
        if uri
          cache_entries.delete(read_cache_key(uri))
          bump_cache_generation(read_cache_key(uri))
        else
          cache_entries.delete_if { |key, _| key.is_a?(String) && key.start_with?('read:') }
          bump_cache_generation(:'read:*')
        end
      end
    end

    # @param uri [String]
    # @return [String]
    def read_cache_key(uri)
      "read:#{uri}"
    end

    # Serve a cached resources/read while fresh; otherwise fetch, and cache
    # the contents unless they came from a multi round-trip retry ("results
    # produced by retrying a request through the multi round-trip requests
    # mechanism MUST NOT be cached").
    # @param uri [String] the resource URI
    # @yield fetches the raw resources/read result
    # @return [Array<MCPClient::ResourceContent>]
    def read_resource_with_cache(uri)
      key = read_cache_key(uri)
      cached = private_entry_for_current_context(key)
      # An invalidation (a resources/updated notification, a cleanup) that
      # lands after the lookup takes the entry out of the map but leaves
      # this reference intact: the copy is made under the lock, and only
      # while the entry is still the one the map holds.
      served = cached && cache_entries_mutex.synchronize do
        next nil unless cache_entries[key].equal?(cached) && cached.value && cached.fresh?(now: monotonic_now)

        cached.value.map(&:dup)
      end
      if served
        release_serving_request_meta
        return served
      end

      epoch = cache_epoch(key)
      started = monotonic_now
      result = yield
      # The TTL runs from receipt — before the response's notifications were
      # dispatched — not from the end of the conversion below.
      received_at = response_received_at(since: started)
      unless result.is_a?(Hash)
        raise MCPClient::Errors::TransportError,
              "Invalid resources/read response: expected an object, got #{result.class}"
      end

      # Projecting `contents` out of an unfinished answer would present it as
      # an empty successful read -- and cache it. The guard runs before both.
      require_complete_result!(result, 'resources/read')
      contents = (result['contents'] || []).map { |content| MCPClient::ResourceContent.from_json(content) }
      entry = cache_entry_for(result, contents, now: received_at)
      # A read is cached only on an explicit, positive ttlMs: "if ttlMs is
      # absent, clients SHOULD assume 0" — and reads were never cached
      # before this revision, so a legacy server keeps that behaviour; a
      # result that is stale on arrival would only take up memory. A result
      # reached through a multi round-trip retry MUST NOT be cached either,
      # nor one whose entry was invalidated while the request was in flight.
      store_read_entry(key, entry, replacing: cached, epoch: epoch, now: received_at)
      # The caller gets its own copies; the cached ones stay untouched.
      contents.map(&:dup)
    end

    # Store a read's entry, or drop the slot it replaces. An uncacheable
    # result is not stored, and the slot is dropped only when it still holds
    # the entry the read set out to replace (its own context's, seen when it
    # started): another context's private entry, or one a later fetch
    # installed meanwhile, stays.
    # @param key [String] the read cache key
    # @param entry [MCPClient::CachedResult] the read's entry
    # @param replacing [MCPClient::CachedResult, nil] the entry seen when the read started
    # @param epoch [Integer] the cache epoch when the read started
    # @param now [Float] the receipt time
    # @return [void]
    def store_read_entry(key, entry, replacing:, epoch:, now:)
      cache_entries_mutex.synchronize do
        if last_result_from_round_trip? || !entry.hint? || !entry.fresh?(now: now)
          cache_entries.delete(key) if replacing && cache_entries[key].equal?(replacing)
        elsif epoch == cache_generation(key)
          prune_read_entries(now: now)
          cache_entries[key] = entry
        end
      end
    end

    # Drop expired reads and, past {MAX_CACHED_READS}, the oldest ones, so
    # a long-lived connection does not accumulate every URI ever read.
    # (call while holding cache_entries_mutex)
    # @param now [Float] monotonic time
    # @return [void]
    def prune_read_entries(now:)
      reads = cache_entries.select { |k, _| k.is_a?(String) && k.start_with?('read:') }
      reads.each { |k, entry| cache_entries.delete(k) unless entry.fresh?(now: now) }
      reads = cache_entries.select { |k, _| k.is_a?(String) && k.start_with?('read:') }
      while reads.size >= MAX_CACHED_READS
        oldest = reads.min_by { |_, entry| entry.received_at }.first
        cache_entries.delete(oldest)
        reads.delete(oldest)
      end
    end

    # Keep caches in step with the server's change notifications: a list
    # change drops that list (and, for resources, every cached read), a
    # resource update drops that resource's read.
    # @param method [String] a notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    # A host layered above the transport (MCPClient::Client) keeps caches of
    # its own, and they must be gone before a subscription listener runs —
    # the listener is delivered right after this returns, while the host's
    # own notification callback runs last, after the delivery, so that host
    # code cannot hold the delivery up.
    # @yieldparam method [String] the notification method
    # @yieldparam params [Hash, nil] the notification params
    # @return [void]
    def on_cache_invalidation(&block)
      @cache_invalidation_callback = block
    end

    def invalidate_cache_for_notification(method, params = nil)
      kinds = LIST_CHANGE_NOTIFICATIONS[method]
      if kinds
        kinds.each do |kind|
          invalidate_cache(kind)
          invalidate_list_cache(kind) if respond_to?(:invalidate_list_cache, true)
          invalidate_read_cache if kind == :resources
        end
      elsif method == 'notifications/resources/updated'
        uri = params.is_a?(Hash) ? params['uri'] : nil
        invalidate_read_cache(uri) if uri.is_a?(String)
      end
    end
  end
end
