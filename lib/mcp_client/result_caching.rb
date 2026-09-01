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
      'notifications/tools/list_changed' => :tools,
      'notifications/prompts/list_changed' => :prompts,
      'notifications/resources/list_changed' => :resources
    }.freeze

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
      @cache_entries ||= {}
    end

    # @return [Mutex]
    def cache_entries_mutex
      @cache_entries_mutex ||= Mutex.new
    end

    # Record the freshness hint of one result.
    # @param kind [Symbol, String] :tools, :prompts, :resources, :templates, :discover or "read:<uri>"
    # @param result [Hash] the CacheableResult
    # @param value [Object] what the cache holds for this kind (may be nil: hint only)
    # @return [MCPClient::CachedResult]
    def record_cache_hint(kind, result, value = nil)
      entry = MCPClient::CachedResult.from_result(result, value, now: monotonic_now)
      cache_entries_mutex.synchronize { cache_entries[kind] = entry }
      entry
    end

    # Record the hint of an auto-paginated list from its pages (shortest TTL wins).
    # @param kind [Symbol] the list kind
    # @param page_results [Array<Hash>] the per-page results
    # @param value [Object] what the cache holds (may be nil)
    # @return [MCPClient::CachedResult, nil]
    def record_paginated_cache_hint(kind, page_results, value = nil)
      now = monotonic_now
      entries = page_results.grep(Hash).map { |r| MCPClient::CachedResult.from_result(r, nil, now: now) }
      return nil if entries.empty?

      combined = MCPClient::CachedResult.combine(entries, value, now: now)
      cache_entries_mutex.synchronize { cache_entries[kind] = combined }
      combined
    end

    # Called by the paginated list helper with the raw page results.
    # @param method [String] the list method
    # @param page_results [Array<Hash>]
    # @return [void]
    def record_list_cache_hint(method, page_results)
      kind = LIST_METHOD_KINDS[method]
      record_paginated_cache_hint(kind, page_results) if kind
    end

    # Whether the cached response for a kind may still be served. No entry
    # (nothing cached yet) or no hint (older server) means the client's own
    # heuristic applies: cache until a change notification.
    # @param kind [Symbol, String]
    # @return [Boolean]
    def cache_fresh?(kind)
      entry = cache_entries_mutex.synchronize { cache_entries[kind] }
      entry.nil? || entry.fresh?(now: monotonic_now)
    end

    # The freshness hint recorded for an operation.
    # @param kind [Symbol] :discover, :tools, :prompts, :resources, :templates or :read
    # @param key [String, nil] the resource URI for :read
    # @return [Hash, nil] ttl_ms, cache_scope, received_at, fresh — nil when nothing was recorded
    def cache_info(kind, key = nil)
      entry = cache_entries_mutex.synchronize { cache_entries[kind == :read ? read_cache_key(key) : kind] }
      entry&.to_info(now: monotonic_now)
    end

    # Forget the hint (and cached value) for a kind.
    # @param kind [Symbol, String]
    # @return [void]
    def invalidate_cache(kind)
      cache_entries_mutex.synchronize { cache_entries.delete(kind) }
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
      cached = cache_entries_mutex.synchronize { cache_entries[key] }
      return cached.value.dup if cached&.value && cached.fresh?(now: monotonic_now)

      result = yield
      contents = ((result.is_a?(Hash) && result['contents']) || []).map do |content|
        MCPClient::ResourceContent.from_json(content)
      end
      if last_result_from_round_trip?
        invalidate_cache(key)
      else
        record_cache_hint(key, result, contents)
      end
      contents
    end

    # @return [Boolean] whether the last resolved request went through a multi round-trip retry
    def last_result_from_round_trip?
      defined?(@last_result_from_round_trip) && @last_result_from_round_trip == true
    end

    # Keep caches in step with the server's change notifications: a list
    # change drops that list (and, for resources, every cached read), a
    # resource update drops that resource's read.
    # @param method [String] a notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def invalidate_cache_for_notification(method, params = nil)
      kind = LIST_CHANGE_NOTIFICATIONS[method]
      if kind
        invalidate_cache(kind)
        invalidate_list_cache(kind) if respond_to?(:invalidate_list_cache, true)
        invalidate_read_cache if kind == :resources
      elsif method == 'notifications/resources/updated'
        uri = params.is_a?(Hash) ? params['uri'] : nil
        invalidate_read_cache(uri) if uri.is_a?(String)
      end
    end
  end
end
