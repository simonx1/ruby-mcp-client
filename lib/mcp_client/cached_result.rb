# frozen_string_literal: true

module MCPClient
  # A cached server result with its freshness hint (MCP 2026-07-28
  # server/utilities/caching): `ttlMs` says how long the client MAY consider
  # the result fresh after receipt (0 = immediately stale; absent = no hint,
  # only older servers), and `cacheScope` whether the response may be shared
  # across authorization contexts ("public") or not ("private").
  class CachedResult
    SCOPES = %w[public private].freeze

    # @return [Object] the cached value (whatever the caller stored)
    attr_reader :value
    # @return [Float] monotonic receipt time (seconds)
    attr_reader :received_at
    # @return [Integer, Float, nil] the server's ttlMs (nil when it sent none)
    attr_reader :ttl_ms
    # @return [String, nil] "public", "private", or nil when absent/unknown
    attr_reader :cache_scope

    # Build an entry from a CacheableResult.
    # @param result [Hash, nil] the JSON-RPC result carrying ttlMs/cacheScope
    # @param value [Object] what to cache
    # @param now [Float] monotonic receipt time
    # @return [CachedResult]
    def self.from_result(result, value, now:)
      ttl = result.is_a?(Hash) && result.key?('ttlMs') ? normalize_ttl(result['ttlMs']) : nil
      scope = result.is_a?(Hash) ? result['cacheScope'] : nil
      new(value: value, received_at: now, ttl_ms: ttl, cache_scope: SCOPES.include?(scope) ? scope : nil)
    end

    # Combine the hints of several pages of one list into one entry: the
    # shortest TTL wins, and one private page makes the whole list private.
    # @param entries [Array<CachedResult>] per-page entries
    # @param value [Object] the combined value
    # @param now [Float] monotonic receipt time
    # @return [CachedResult]
    def self.combine(entries, value, now:)
      hinted = entries.select(&:hint?)
      # Each page expires at its own received_at + ttlMs; the combined entry
      # (received now) lives until the earliest of those.
      ttl = hinted.map { |e| [e.ttl_ms - ((now - e.received_at) * 1000.0), 0].max }.min
      scope = if entries.any? { |e| e.cache_scope == 'private' }
                'private'
              else
                entries.map(&:cache_scope).compact.first
              end
      new(value: value, received_at: now, ttl_ms: ttl, cache_scope: scope)
    end

    # An entry that is stale from the start: what a change notification
    # leaves behind so the kind reads as "known and stale", not "unknown".
    # @param now [Float] monotonic time
    # @return [CachedResult]
    def self.stale(now:)
      new(value: nil, received_at: now, ttl_ms: 0, cache_scope: nil)
    end

    # "Servers MUST provide a ttlMs value that is >= 0"; anything else is
    # treated as 0 (immediately stale).
    # @param raw [Object] the ttlMs member
    # @return [Integer, Float]
    def self.normalize_ttl(raw)
      return 0 unless raw.is_a?(Numeric) && raw.finite?

      [raw, 0].max
    end

    def initialize(value:, received_at:, ttl_ms:, cache_scope:)
      @value = value
      @received_at = received_at
      @ttl_ms = ttl_ms
      @cache_scope = cache_scope
    end

    # @return [Boolean] whether the server gave a ttlMs at all
    def hint?
      !@ttl_ms.nil?
    end

    # Fresh while now < t_received + ttlMs. Without a hint the client keeps
    # its own heuristic (cache until a change notification), so the entry
    # counts as fresh.
    # @param now [Float] monotonic time
    # @return [Boolean]
    def fresh?(now:)
      return true unless hint?

      now < @received_at + (@ttl_ms / 1000.0)
    end

    # @param now [Float] monotonic time
    # @return [Hash] ttl_ms, cache_scope, received_at, fresh
    def to_info(now:)
      { ttl_ms: @ttl_ms, cache_scope: @cache_scope, received_at: @received_at, fresh: fresh?(now: now) }
    end
  end
end
