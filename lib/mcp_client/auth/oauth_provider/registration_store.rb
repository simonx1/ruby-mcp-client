# frozen_string_literal: true

module MCPClient
  module Auth
    class OAuthProvider
      # Where OAuth client registration state lives, and which record answers
      # for the authorization server in use.
      #
      # MCP 2026-07-28 (SEP-2352) makes registration state per authorization
      # server: a client_id (and the secret that may come with it) is issued
      # by one authorization server and means nothing at another. One MCP
      # server can be served by more than one authorization server over its
      # lifetime — a migration, a challenge that names another one, a host
      # that configures a second — so credentials keyed by the resource URL
      # alone cannot hold both: configuring the second replaces the first, and
      # coming back to the first reports "these credentials belong to another
      # authorization server" instead of finding its registration.
      #
      # So every record is additionally kept under a key of its own
      # authorization server ({#client_registration_key}), while the resource
      # URL stays the key of the registration currently in use. That keeps the
      # documented storage interface intact — a backend still sees opaque
      # string keys, and records written by earlier versions are found where
      # they were left — while giving each authorization server registration
      # state of its own.
      #
      # Mixed into OAuthProvider; every method relies on its state.
      module RegistrationStore
        # The storage key the registration state of one authorization server
        # is kept under. The resource URL itself is the key of the record in
        # use (and of records persisted before this layout existed); each
        # authorization server additionally has a key derived from the
        # resource URL and its issuer identifier, so a host can configure
        # credentials for several authorization servers behind one MCP server:
        #
        #   storage.set_client_info(provider.client_registration_key(issuer), credentials)
        #
        # A normalized server URL never carries a fragment, so the separator
        # cannot collide with a resource URL.
        # @param issuer [String, nil] the issuer identifier of the authorization server
        # @return [String] the storage key for that server's registration state
        def client_registration_key(issuer)
          return server_url unless issuer.is_a?(String) && !issuer.empty? && issuer != Token::RETIRED_ISSUER

          "#{server_url}#authorization_server=#{issuer}"
        end

        private

        # Get or register OAuth client, following the MCP 2025-11-25 client
        # registration priority order: pre-registered/cached client information
        # first, then Client ID Metadata Documents (SEP-991) when the
        # authorization server advertises support and a metadata URL is
        # configured, then Dynamic Client Registration as a fallback.
        # @param server_metadata [ServerMetadata] Authorization server metadata
        # @return [ClientInfo] Client information
        # @raise [MCPClient::Errors::ConnectionError] if registration fails
        def get_or_register_client(server_metadata)
          # 1. Credentials for the authorization server in use: its own
          # registration state first, then the resource slot.
          if (client_info = usable_client_info(server_metadata))
            logger.debug("Using cached OAuth client for #{server_url}")
            return client_info
          end

          # 2. Client ID Metadata Documents (SEP-991): the HTTPS metadata URL is
          # itself the client_id — no registration request is needed.
          if client_id_metadata_url && server_metadata.supports_client_id_metadata_documents?
            return client_info_from_metadata_url
          end

          # 3. Dynamic Client Registration (RFC 7591) fallback
          logger.debug('No cached client found, registering new OAuth client...')
          if server_metadata.supports_registration?
            register_client(server_metadata)
          else
            raise MCPClient::Errors::ConnectionError,
                  'Dynamic client registration not supported and no client credentials found'
          end
        end

        # The stored credentials the authorization server in use accepts, or
        # nil when the client has to register with it.
        # @param server_metadata [ServerMetadata] the authorization server in use
        # @return [ClientInfo, nil]
        # @raise [MCPClient::Errors::ConnectionError] for pre-registered credentials of another issuer
        def usable_client_info(server_metadata)
          issuer = server_metadata.issuer
          in_use = stored_client_info
          in_use = nil if in_use&.client_secret_expired?
          # Credentials a host pre-registered WITH THIS authorization server
          # come first, as the MCP 2026-07-28 client registration priority
          # order says they should. A Client ID Metadata Document id is
          # portable, so it answers for every authorization server; without
          # this it would also answer for one the host gave credentials of its
          # own — a registration with different permissions, and possibly a
          # different consent policy, silently passed over because a portable
          # id happened to be in the slot.
          if portable_record?(in_use) && (pre_registered = pre_registered_for_issuer(issuer))
            return adopt_client_info(pre_registered, issuer)
          end

          # The registration in use answers whenever the authorization server
          # in use can be asked to accept it. It is the slot a host writes to,
          # so credentials rotated there are never overruled by an older copy
          # kept under the same authorization server's key.
          if answers_for_issuer?(in_use, issuer) &&
             (accepted = client_info_for_issuer(in_use, issuer, server_metadata))
            return accepted
          end

          # Otherwise the registration made with THIS authorization server, if
          # one was kept: another server having taken the resource slot does
          # not revoke it (SEP-2352).
          own = registration_for_issuer(issuer)
          return adopt_client_info(own, issuer) if own
          # A record of another authorization server, with nothing kept for
          # this one, is reported (pre-registered) or discarded (dynamic).
          return nil if in_use.nil? || answers_for_issuer?(in_use, issuer)

          client_info_for_issuer(in_use, issuer, server_metadata)
        end

        # Whether the registration in use is one the authorization server in
        # use can be asked to accept: bound to it, not bound at all (a record
        # persisted before issuers were recorded), or portable.
        # @param client_info [ClientInfo, nil]
        # @param issuer [String] the issuer of the authorization server in use
        # @return [Boolean]
        def answers_for_issuer?(client_info, issuer)
          return false unless client_info
          return true unless client_info.respond_to?(:issuer)

          client_info.issuer.nil? || client_info.issuer == issuer || portable_client?(client_info)
        end

        # The registration state kept for one authorization server, if it is
        # usable: bound to that server and with a secret that has not expired.
        # @param issuer [String, nil] the issuer identifier
        # @return [ClientInfo, nil]
        def registration_for_issuer(issuer)
          key = client_registration_key(issuer)
          return nil if key == server_url

          record = read_client_info(key)
          return nil unless record && record_bound_to?(record, issuer) && !record.client_secret_expired?

          record
        end

        # One read of a per-issuer key. A backend given a key it has never
        # seen answers nil, but one that validates its keys may object, and
        # not having that record is not a reason to fail a flow: it is the
        # same answer as an empty slot, and the resource slot is consulted
        # next.
        # @param key [String] the storage key
        # @return [ClientInfo, nil]
        def read_client_info(key)
          stored_client_info(key)
        rescue StandardError => e
          logger.debug("The OAuth client registration under #{key.inspect} could not be read (#{e.class})")
          nil
        end

        # Make these credentials the ones the resource slot holds, so every
        # resource-keyed read — the code exchange, the refresh, the check that
        # the credentials did not change during a flow — sees the registration
        # in use. Whatever they displace is kept under its own authorization
        # server's key first.
        # @param client_info [ClientInfo] the credentials to put in use
        # @param issuer [String] the authorization server they belong to
        # @return [ClientInfo] the same credentials
        def adopt_client_info(client_info, issuer)
          current = stored_client_info
          return client_info if current && current.client_id == client_info.client_id &&
                                record_bound_to?(current, issuer)

          preserve_client_registration(current)
          write_client_info!(client_info)
          client_info
        end

        # MCP 2026-07-28 "Authorization Server Binding": credentials are keyed
        # by the issuer that produced them. A Client ID Metadata Document
        # client id is portable; unbound credentials are bound to the current
        # issuer on first use; pre-registered credentials for another issuer
        # are an error rather than silently reused; a dynamic registration for
        # another issuer is discarded so the caller re-registers — and is kept
        # under its own authorization server's key either way, so returning to
        # that server finds it again.
        # @param client_info [ClientInfo] the cached credentials
        # @param issuer [String] the issuer of the authorization server in use
        # @return [ClientInfo, nil] usable credentials, or nil when a new registration is needed
        # @raise [MCPClient::Errors::ConnectionError] for pre-registered credentials of another issuer
        # @param server_metadata [ServerMetadata, nil] the authorization server in use
        def client_info_for_issuer(client_info, issuer, server_metadata = nil)
          return client_info unless client_info.respond_to?(:issuer)

          if portable_client?(client_info)
            # A portable id is only usable where Client ID Metadata Documents
            # are accepted; elsewhere the caller registers or reports that no
            # credentials exist.
            return nil if server_metadata && !server_metadata.supports_client_id_metadata_documents?
            # A Client ID Metadata Document client persisted before the type
            # was recorded is migrated so later checks need no inference.
            return client_info if client_info.registration_type == 'cimd'

            migrated = client_info.with_issuer(client_info.issuer, registration_type: 'cimd')
            store_client_info(migrated)
            return migrated
          end

          if client_info.issuer.nil?
            bound = client_info.with_issuer(issuer, registration_type: resolved_registration_type(client_info))
            store_client_info(bound)
            return bound
          end
          return preserved_client_info(client_info) if client_info.issuer == issuer

          if client_info.pre_registered?
            preserve_client_registration(client_info)
            raise MCPClient::Errors::ConnectionError,
                  'Pre-registered OAuth client credentials belong to authorization server ' \
                  "#{safe_error_text(client_info.issuer)}, but the server now uses #{safe_error_text(issuer)}; " \
                  'register the client with the new authorization server'
          end

          logger.warn("Discarding the OAuth client registered with #{safe_error_text(client_info.issuer)}: " \
                      "the authorization server is now #{safe_error_text(issuer)}")
          preserve_client_registration(client_info)
          delete_client_info
          delete_token(bind_to: client_info.issuer)
          nil
        end

        # Storage backends may persist plain hashes (the FileTokenStorage
        # example does); records are normalized before any field is read.
        # @param key [String] the storage key to read (the resource slot by default)
        # @return [ClientInfo, nil]
        def stored_client_info(key = server_url)
          client_info = normalize_record(storage.get_client_info(key), ClientInfo)
          # A backend without delete_client_info is asked to store nil, and one
          # that persists plain hashes writes `nil.to_h` — `{}`. Read back that
          # is a record without a client id, which would be bound to the current
          # issuer and reused instead of registering, making an authorization
          # request with an empty client_id. A hash-persisting backend can just
          # as well read back a client_id of any other JSON type, which would go
          # into the authorization URL `to_s`-mangled and be rejected only on
          # the way back, after the browser had been opened. Neither is a
          # client: both are the absence storage meant to express, so
          # registration happens first. The bytes are required exactly as a
          # token's are.
          return nil if client_info.respond_to?(:client_id) && !client_id_bytes?(client_info.client_id)

          client_info
        end

        # Persist credentials as the registration in use and, when they are
        # bound to an authorization server, as that server's registration
        # state, so a later return to it finds them.
        # @param client_info [ClientInfo]
        # @return [void]
        def store_client_info(client_info)
          write_client_info!(client_info)
          preserve_client_registration(client_info)
        end

        # Keep a record under its own authorization server's key. Records that
        # name no authorization server (a portable Client ID Metadata Document
        # client, a retired one) have no key of their own and stay where they
        # are.
        # @param client_info [ClientInfo, nil]
        # @return [void]
        def preserve_client_registration(client_info)
          return unless client_info.respond_to?(:issuer)

          key = client_registration_key(client_info.issuer)
          return if key == server_url

          write_client_info(key, client_info)
        end

        # @param client_info [ClientInfo] credentials that are already in use
        # @return [ClientInfo] the same credentials, kept under their own key too
        def preserved_client_info(client_info)
          preserve_client_registration(client_info)
          client_info
        end

        # One write to the storage backend under a per-authorization-server
        # key. A backend that refuses a key it has not seen before must not
        # take down a flow whose credentials are in hand: this copy is a
        # convenience for a later switch, and the registration in use is
        # written by {#write_client_info!}.
        # @param key [String] the storage key
        # @param client_info [ClientInfo, nil]
        # @return [void]
        def write_client_info(key, client_info)
          storage.set_client_info(key, client_info)
        rescue StandardError => e
          logger.debug("The OAuth client registration could not be stored under #{key.inspect} (#{e.class})")
        end

        # The write the flow depends on. {#complete_authorization_flow} reads
        # the resource slot to redeem the code, so credentials that never
        # reached it produce an authorization URL the user follows and a
        # callback that answers "Missing PKCE or client info" — a failure
        # after consent, blamed on the callback. A backend that cannot store
        # them says so now, before the browser is opened. (The optional
        # per-issuer copy is still best-effort; only this one is essential.)
        # @param client_info [ClientInfo] the credentials the flow will use
        # @return [void]
        # @raise [MCPClient::Errors::ConnectionError] when the backend refuses the write
        def write_client_info!(client_info)
          storage.set_client_info(server_url, client_info)
        rescue StandardError => e
          raise MCPClient::Errors::ConnectionError,
                "The OAuth client registration could not be stored (#{e.class}: " \
                "#{safe_error_text(e.message)}); the authorization cannot continue"
        end

        # The registration type of stored credentials, recognizing a Client
        # ID Metadata Document client persisted before the type was recorded
        # by its client id (the configured metadata URL).
        # @param client_info [ClientInfo]
        # @return [String]
        def resolved_registration_type(client_info)
          return client_info.registration_type if client_info.registration_type
          return 'cimd' if client_id_metadata_url && client_info.client_id == client_id_metadata_url

          client_info.effective_registration_type
        end

        # @param client_info [ClientInfo]
        # @return [Boolean] whether the client id is portable across authorization servers
        def portable_client?(client_info)
          resolved_registration_type(client_info) == 'cimd'
        end

        # @param client_info [ClientInfo, nil] a record read from storage
        # @return [Boolean] whether it is a portable (Client ID Metadata Document) registration
        def portable_record?(client_info)
          client_info.respond_to?(:registration_type) && portable_client?(client_info)
        end

        # The credentials a host pre-registered with one authorization server,
        # if it did. A dynamic registration is not one: it is this client's
        # own record of a registration it made, which a portable id does not
        # displace.
        # @param issuer [String, nil] the issuer identifier
        # @return [ClientInfo, nil]
        def pre_registered_for_issuer(issuer)
          record = registration_for_issuer(issuer)
          record if record.respond_to?(:pre_registered?) && record.pre_registered?
        end

        # Forget the registration in use. The per-issuer record of the
        # authorization server it belonged to is deliberately kept: that
        # registration is still valid at that server (SEP-2352), and it is the
        # resource slot — the answer to "which credentials does this MCP
        # server use now" — that a server change invalidates.
        # @return [void]
        def delete_client_info
          # Prefer an explicit delete; fall back to the always-available
          # set_client_info(nil) so custom storage backends are handled too.
          # A backend that refuses either must not stop the authorization
          # server switch: the credentials stay bound to the previous issuer
          # and are discarded again by the next flow.
          if storage.respond_to?(:delete_client_info)
            storage.delete_client_info(server_url)
          else
            storage.set_client_info(server_url, nil)
          end
        rescue StandardError => e
          logger.warn('The OAuth client registration for the previous authorization server could not be removed ' \
                      "from storage (#{e.class}); implement delete_client_info(server_url) on the storage backend.")
        end

        # Build client information for a Client ID Metadata Document client
        # (SEP-991): the configured HTTPS metadata URL is used directly as the
        # client_id in authorization and token requests, without a dynamic
        # registration POST. Serving the metadata JSON at that URL is the
        # application's responsibility, not this library's.
        # @return [ClientInfo] Client information with the metadata URL as client_id
        def client_info_from_metadata_url
          logger.debug("Using Client ID Metadata Document URL as client_id: #{client_id_metadata_url}")

          metadata = ClientMetadata.new(
            redirect_uris: [redirect_uri],
            token_endpoint_auth_method: 'none', # Public client
            grant_types: %w[authorization_code refresh_token],
            response_types: ['code'],
            scope: resolved_scope,
            **@extra_client_metadata
          )

          client_info = ClientInfo.new(client_id: client_id_metadata_url, metadata: metadata,
                                       registration_type: 'cimd')

          # Persist so complete_authorization_flow and token refresh can find it
          store_client_info(client_info)

          client_info
        end
      end
    end
  end
end
