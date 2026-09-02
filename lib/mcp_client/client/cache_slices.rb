# frozen_string_literal: true

module MCPClient
  class Client
    # The client's own slices of a list cache under the MCP 2026-07-28
    # caching rules: whether every server's slice is still fresh and current
    # for the parameters a listing would send, the snapshot a fresh cache
    # yields, and the replacement of one server's slice by a fresh fetch
    # without disturbing the others. Mixed into {MCPClient::Client}; every
    # method is private there.
    module CacheSlices
      private

      # Whether every server's cached list of a kind is still fresh (MCP
      # 2026-07-28 caching: a stale list is re-fetched on access).
      # The parameters go first: reading them evaluates the host's request_meta
      # and the transport holds that evaluation, which the freshness check then
      # reuses instead of reading the callable a second time. Asking the other
      # way round released the held value in between, so a hit spent two
      # trace ids (or nonces) on a decision that sends nothing.
      # @param kind [Symbol] :tools, :prompts or :resources
      # @return [Boolean]
      def caches_fresh?(kind)
        servers.all? do |server|
          cache_params_current?(kind, server) && (!server.respond_to?(:cache_fresh?) || server.cache_fresh?(kind))
        end
      rescue StandardError
        # One server's check aborted -- an OAuth refresh that failed, a host
        # `request_meta` callable that raised -- so nothing is fetched from any
        # of them. Every server the loop had already passed is still holding
        # the evaluation this decision read for the fetch it would have made:
        # dropped here, all of them, or an unrelated request on this worker
        # thread would go out carrying that decision's tenant, baggage or nonce.
        release_held_request_meta
        raise
      end

      # The cache's items as one snapshot taken under the lock, when the cache
      # holds something and every server's slice is fresh for the parameters
      # its next request would carry.
      # @param kind [Symbol]
      # @param cache [Hash]
      # @return [Array, nil]
      def cached_snapshot(kind, cache)
        # Freshness consults the servers (a request_meta callable, host
        # middleware), which may clear this cache in turn: it runs outside the
        # lock, and the copy is served only when nothing changed meanwhile.
        version = @cache_mutex.synchronize { @cache_version }
        # An empty snapshot is a hit too: a server may list nothing, and its
        # entry says so for as long as it is fresh. What makes a hit is that
        # every server has filled its slice, not that the hash holds items.
        return nil unless @cache_mutex.synchronize { snapshot_complete?(kind, cache) }
        return nil unless caches_fresh?(kind)

        @cache_mutex.synchronize do
          # A cleanup that landed after the verdict replaced the transport
          # entries the slices came from; that check touches only the
          # transport's cache lock, so it can run under this one.
          next unless version == @cache_version && snapshot_complete?(kind, cache) && slices_still_current?(kind)

          cached_copies(cache)
        end
      end

      # Whether every server this client talks to has filled its slice of a
      # list cache (an empty list fills a slice as much as a long one does).
      # Called under {@cache_mutex}.
      # @param kind [Symbol]
      # @param cache [Hash] the kind's cache, to tell an empty snapshot apart
      # @return [Boolean]
      def snapshot_complete?(kind, cache)
        filled = @cache_filled[kind]
        return false if filled.nil?

        list = servers
        return false if list.empty? || !list.all? { |server| filled.key?(server) }
        # A snapshot with nothing in it is only a hit while a server says so
        # itself: a 2026-07-28 server bounds its empty list with a ttlMs, an
        # older one records no hint at all and keeps the client's previous
        # heuristic — ask again until something is listed.
        return true unless cache.empty?

        list.all? { |server| hinted_slice?(kind, server) }
      end

      # @param kind [Symbol]
      # @param server [MCPClient::ServerBase]
      # @return [Boolean] whether the entry behind this server's slice bounds
      #   its own freshness (the server sent a hint)
      def hinted_slice?(kind, server)
        server.respond_to?(:cache_entry_hinted?, true) && server.send(:cache_entry_hinted?, kind)
      end

      # Whether every server's slice of a kind still comes from the transport
      # entry it was recorded against (a cleanup or a replaced entry ends it).
      # @param kind [Symbol]
      # @return [Boolean]
      def slices_still_current?(kind)
        servers.all? do |server|
          next true unless server.respond_to?(:cache_entry_token, true)

          _fingerprint, token = @cache_params[kind][server]
          current = server.send(:cache_entry_token, kind)
          next current.nil? if token == MCPClient::ResultCaching::LEGACY_ENTRY
          next false unless !token.nil? && !current.nil? && current.equal?(token)

          # The verdict may be old by the time the copy is made: the entry's
          # own hint is re-read here (transport cache lock only).
          !server.respond_to?(:cache_entry_fresh?, true) || server.send(:cache_entry_fresh?, kind)
        end
      end

      # Replace one server's slice of a list cache under the lock: its previous
      # entries go, the fingerprint the fetch was made under is recorded, and
      # the block inserts the new entries.
      # @param kind [Symbol]
      # @param cache [Hash]
      # @param server [MCPClient::ServerBase]
      # @param fingerprint [String, nil]
      # @return [void]
      def replace_cached_slice(kind, cache, server, fingerprint, generation: nil)
        @cache_mutex.synchronize do
          # An invalidation that landed while the fetch ran already replaced
          # these definitions; writing them back would undo it.
          next if generation && @tool_cache_generation != generation

          @cache_version += 1
          drop_cached_entries(cache, server)
          # This server's slice now stands for its whole list, empty or not.
          (@cache_filled[kind] ||= {}.compare_by_identity)[server] = true
          forget_schema_checks(server) if kind == :tools
          if server.respond_to?(:current_params_fingerprint, true)
            # The slice is tied to the very transport entry its list came
            # from — its identity and the parameters that entry is bound to
            # (the request that produced it, which a first fetch may have made
            # with more than was known before connecting): a transport list
            # refreshed on its own (rotated credentials, a concurrent fetch)
            # replaces that entry, and the slice with it.
            token, bound = served_entry_for(kind, server)
            @cache_params[kind][server] = [bound || fingerprint, token]
          end
          yield
        end
      end

      # @return [Array(Object, String), nil] the identity of the transport
      #   entry the list this thread just obtained from the server came from,
      #   and the parameters fingerprint it is bound to
      def served_entry_for(kind, server)
        return nil unless server.respond_to?(:take_served_entry, true)

        # Taken rather than read: the note exists for this one tagging, and
        # leaving it behind would keep a slot on this thread for every
        # transport a long-lived worker has ever listed through.
        server.send(:take_served_entry, kind)
      end

      # @return [Boolean] whether the server's next request would carry the
      #   parameters its slice of the cache was filled under, and the transport
      #   still holds the entry that slice came from
      def cache_params_current?(kind, server)
        return true unless server.respond_to?(:current_params_fingerprint, true)

        fingerprint, token = @cache_params[kind][server]
        return false unless fingerprint == server.send(:current_params_fingerprint)
        return true unless server.respond_to?(:cache_entry_token, true)

        # A slice is identified by the very entry it came from; a legacy list
        # (no hint recorded) stays a hit only while the transport still holds
        # no entry, and a fetch that recorded no entry identifies nothing.
        current = server.send(:cache_entry_token, kind)
        return current.nil? if token == MCPClient::ResultCaching::LEGACY_ENTRY

        !token.nil? && !current.nil? && current.equal?(token)
      end

      # The cache's items as copies: a caller can neither change the cache nor
      # what later callers (and the x-mcp-header derivation) see.
      # @param cache [Hash]
      # @return [Array]
      def cached_copies(cache)
        cache.values.map { |item| MCPClient::DeepCopy.copy(item) }
      end

      # Remove one server's entries from a client-level cache.
      # @param cache [Hash] the cache keyed by #cache_key_for
      # @param server [MCPClient::ServerBase]
      # @return [void]
      def drop_cached_entries(cache, server)
        prefix = "#{server.object_id}:"
        cache.delete_if { |key, _| key.start_with?(prefix) }
      end
    end
  end
end
