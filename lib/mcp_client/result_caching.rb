# frozen_string_literal: true

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

    # @return [Hash{Object => MCPClient::CachedResult}]
    def cache_entries
      @cache_entries || CACHE_INIT_LOCK.synchronize { @cache_entries ||= {} }
    end

    # @return [Mutex]
    def cache_entries_mutex
      @cache_entries_mutex || CACHE_INIT_LOCK.synchronize { @cache_entries_mutex ||= Mutex.new }
    end

    # A counter bumped by every invalidation, so a response that was in
    # flight while its cache entry was invalidated is not written back.
    # @return [Integer]
    def cache_epoch
      cache_entries_mutex.synchronize { @cache_epoch || 0 }
    end

    # @return [void] (call while holding cache_entries_mutex)
    def bump_cache_epoch
      @cache_epoch = (@cache_epoch || 0) + 1
    end

    # Record the freshness hint of one result.
    # @param kind [Symbol, String] :tools, :prompts, :resources, :templates, :discover or "read:<uri>"
    # @param result [Hash] the CacheableResult
    # @param value [Object] what the cache holds for this kind (may be nil: hint only)
    # @return [MCPClient::CachedResult]
    def record_cache_hint(kind, result, value = nil)
      entry = cache_entry_for(result, value, now: monotonic_now)
      cache_entries_mutex.synchronize { cache_entries[kind] = entry }
      entry
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
    def record_paginated_cache_hint(kind, page_results, value = nil, received_ats: nil, contexts: nil, epoch: nil)
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
      # A private list whose pages were fetched under different credentials
      # belongs to no single context; a list invalidated while it was being
      # fetched is already stale.
      mixed = combined.cache_scope == 'private' && contexts && contexts.uniq.size > 1
      cache_entries_mutex.synchronize do
        if mixed || (epoch && epoch != (@cache_epoch || 0))
          combined = MCPClient::CachedResult.stale(now: now,
                                                   like: combined)
        end
        combined.authorization_context = nil if mixed
        cache_entries[kind] = combined
      end
      combined
    end

    # Called by the paginated list helper with the raw page results.
    # @param method [String] the list method
    # @param page_results [Array<Hash>]
    # @return [void]
    # @param received_ats [Array<Float>, nil] each page's monotonic receipt time
    # @param contexts [Array<String, nil>, nil] each page's request authorization context
    # @param epoch [Integer, nil] the cache epoch when the first page was requested
    def record_list_cache_hint(method, page_results, received_ats = nil, contexts: nil, epoch: nil)
      kind = LIST_METHOD_KINDS[method]
      return unless kind

      record_paginated_cache_hint(kind, page_results, received_ats: received_ats, contexts: contexts, epoch: epoch)
    end

    # Whether the cached response for a kind may still be served. No entry
    # (nothing cached yet) or no hint (older server) means the client's own
    # heuristic applies: cache until a change notification.
    # @param kind [Symbol, String]
    # @return [Boolean]
    def cache_fresh?(kind)
      entry = private_entry_for_current_context(kind)
      entry.nil? || entry.fresh?(now: monotonic_now)
    end

    # The entry for a kind, after making sure a privately scoped one still
    # belongs to the current authorization context (transports that know
    # their context re-check it here; a changed context drops the entry).
    # @param kind [Symbol, String]
    # @return [MCPClient::CachedResult, nil]
    def private_entry_for_current_context(kind)
      entry = cache_entries_mutex.synchronize { cache_entries[kind] }
      return entry if entry_in_current_context?(entry)

      # Another context's private entry reads as known-and-stale, never as
      # "nothing cached" (which would count as fresh) and never as a value.
      MCPClient::CachedResult.stale(now: monotonic_now)
    end

    # @param entry [MCPClient::CachedResult, nil]
    # @return [Boolean] whether the entry may be served in the current authorization context
    # @param context [String, nil, :current] the authorization context to check against
    #   (:current asks the transport which credentials it would send now)
    def entry_in_current_context?(entry, context: :current)
      return true unless entry&.cache_scope == 'private' && respond_to?(:current_authorization_context, true)

      context = current_authorization_context if context == :current
      entry.authorization_context == context
    end

    # The stale copy that may be served when a re-fetch fails: only a list
    # with a known hint, and never a private entry from another
    # authorization context (checked against the credentials the failed
    # request actually used, when the caller knows them).
    # @param kind [Symbol]
    # @param cached [Object, nil] the transport's cached value for the kind
    # @param context [String, nil, :current] the authorization context to check against
    # @return [Object, nil]
    def stale_fallback_for(kind, cached, context: :current)
      return nil unless cached

      entry = cache_entries_mutex.synchronize { cache_entries[kind] }
      return nil if entry.nil?

      entry_in_current_context?(entry, context: context) ? cached : nil
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
        bump_cache_epoch
      end
    end

    # Forget every cached result and hint (the connection, and with it the
    # authorization context, is gone).
    # @return [void]
    def clear_result_cache
      cache_entries_mutex.synchronize do
        cache_entries.clear
        bump_cache_epoch
      end
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
        else
          cache_entries.delete_if { |key, _| key.is_a?(String) && key.start_with?('read:') }
        end
        bump_cache_epoch
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
      return cached.value.dup if cached&.value && cached.fresh?(now: monotonic_now)

      epoch = cache_epoch
      result = yield
      contents = ((result.is_a?(Hash) && result['contents']) || []).map do |content|
        MCPClient::ResourceContent.from_json(content)
      end
      entry = cache_entry_for(result, contents, now: monotonic_now)
      # A read is cached only on an explicit ttlMs: "if ttlMs is absent,
      # clients SHOULD assume 0" — and reads were never cached before this
      # revision, so a legacy server keeps that behaviour. A result reached
      # through a multi round-trip retry MUST NOT be cached either, nor one
      # whose entry was invalidated while the request was in flight.
      if last_result_from_round_trip? || !entry.hint?
        invalidate_read_cache(uri)
      else
        cache_entries_mutex.synchronize { cache_entries[key] = entry if epoch == (@cache_epoch || 0) }
      end
      # The caller gets its own array; the cached one stays untouched.
      contents.dup
    end

    # Keep caches in step with the server's change notifications: a list
    # change drops that list (and, for resources, every cached read), a
    # resource update drops that resource's read.
    # @param method [String] a notification method
    # @param params [Hash, nil] notification params
    # @return [void]
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
