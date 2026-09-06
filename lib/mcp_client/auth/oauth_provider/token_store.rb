# frozen_string_literal: true

module MCPClient
  module Auth
    class OAuthProvider
      # Where the OAuth tokens of one MCP server live, and which token
      # answers for the authorization server in use.
      #
      # MCP 2026-07-28 makes registration state per authorization server, and
      # names what that state is: "client credentials, tokens". A token is
      # issued by one authorization server, for one resource, and means
      # nothing at another server — so it is stored twice, exactly as a
      # client registration is: under the resource URL, which is the token
      # currently in use and where every backend (and every record written by
      # an earlier version) already keeps it, and under a key of its own
      # authorization server ({RegistrationStore#client_registration_key}).
      #
      # One MCP server can be served by more than one authorization server
      # over its lifetime. With the token kept only under the resource URL, a
      # switch away from a server threw its token away, and coming back meant
      # sending the user through consent again for a grant that was never
      # revoked. The per-authorization-server copy keeps it instead — while a
      # token this client RETIRED stays retired wherever it is kept, and a
      # token is still never presented to an authorization server other than
      # the one that issued it.
      #
      # Mixed into OAuthProvider; every method relies on its state.
      module TokenStore
        private

        # Forget the stored token (the authorization server it came from is no
        # longer the one in use). Storage backends may implement the optional
        # delete_token(server_url); otherwise set_token(server_url, nil) is
        # attempted, and a backend that accepts neither is reported.
        # @return [void]
        # @param bind_to [String, nil] the issuer the token belonged to (or Token::RETIRED_ISSUER): a token
        #   that records no issuer is first re-stored bound to it, so a backend that cannot delete still
        #   keeps it away from another authorization server after a restart
        def delete_token(bind_to: nil)
          # Whatever the backend manages, this token is never presented again.
          current = stored_token
          if current.respond_to?(:access_token) && current.access_token
            # Opaque tokens are unique only within an issuer: the marker names
            # the issuer the bytes were retired for, so another provider
            # sharing the storage may store the same bytes for a new server.
            (@retired_tokens ||= {})[retirement_key(current, bind_to)] = true
            # A token retired outright is retired wherever it is kept: the copy
            # under its own authorization server's key must not hand it back.
            forget_token_of_issuer(current.issuer) if bind_to == Token::RETIRED_ISSUER
          end
          if bind_to && current.respond_to?(:with_issuer) && (current.issuer.nil? || bind_to == Token::RETIRED_ISSUER)
            begin
              storage.set_token(server_url, current.with_issuer(bind_to))
            rescue StandardError => e
              logger.debug("Could not bind the retired token to its issuer in storage: #{e.class}")
            end
          end
          remove_token_in_use
        rescue StandardError => e
          logger.warn('The OAuth token for the previous authorization server could not be removed from storage ' \
                      "(#{e.class}); implement delete_token(server_url) on the storage backend. The token is " \
                      'ignored while the authorization server differs from its issuer.')
        end

        # Empty the slot the token in use is kept in.
        # @return [void]
        def remove_token_in_use
          if storage.respond_to?(:delete_token)
            storage.delete_token(server_url)
          else
            storage.set_token(server_url, nil)
          end
        end

        # The authorization server in use changed, so the token of the previous
        # one is no longer the token in use — but it is still that server's
        # token. MCP 2026-07-28 keeps registration state, "client credentials,
        # tokens", per authorization server, so a token that says which server
        # issued it is set aside under that server's own key instead of being
        # thrown away: a resource served by two authorization servers over its
        # lifetime finds the token again when it comes back to the first,
        # rather than sending the user through consent for a grant that is
        # still valid. Anything else — an unbound token, one already retired —
        # is retired exactly as before: a token that cannot say where it came
        # from cannot be filed under an authorization server either.
        # @param issuer [String, nil] the authorization server that is no longer in use
        # @return [void]
        def withdraw_token(issuer)
          token = stored_token_or_nil
          unless issuer.is_a?(String) && record_bound_to?(token, issuer) && !retired_token?(token)
            delete_token(bind_to: issuer)
            return
          end

          preserve_token(token)
          begin
            remove_token_in_use
          rescue StandardError => e
            logger.warn('The OAuth token for the previous authorization server could not be removed from storage ' \
                        "(#{e.class}); implement delete_token(server_url) on the storage backend. The token is " \
                        'ignored while the authorization server differs from its issuer.')
          end
        end

        # The token of the authorization server in use, wherever it is kept:
        # the slot in use, else the copy set aside under that server's own key
        # when it stopped being the server in use (MCP 2026-07-28 keeps tokens
        # per authorization server). A token from another authorization server
        # is never presented, and retired bytes are refused before any binding
        # could attribute them anew.
        # @return [Token, nil]
        def token_in_use
          token = stored_token
          if token && !retired_token?(token)
            token = bind_token_issuer(token)
            return token if token && token_for_current_issuer?(token)
          end

          adopt_token_kept_for_issuer_in_use
        end

        # Make the token kept for the authorization server in use the token in
        # use again.
        # @return [Token, nil]
        def adopt_token_kept_for_issuer_in_use
          issuer = current_issuer_for_tokens
          kept = issuer && token_kept_for_issuer(issuer)
          return nil unless kept

          logger.debug('Using the OAuth token kept for the authorization server this resource now uses again')
          begin
            storage.set_token(server_url, kept)
          rescue StandardError => e
            logger.debug("The kept OAuth token could not be made the token in use (#{e.class})")
          end
          kept
        end

        # Keep a token under its own authorization server's key, so a later
        # return to that server finds it. Best-effort, exactly like the
        # per-authorization-server copy of a client registration: the slot in
        # use is the one every read depends on.
        # @param token [Token] a token bound to an authorization server
        # @return [void]
        def preserve_token(token)
          return unless token.respond_to?(:issuer)

          key = client_registration_key(token.issuer)
          return if key == server_url

          begin
            storage.set_token(key, token)
          rescue StandardError => e
            logger.debug("The OAuth token could not be stored under #{key.inspect} (#{e.class})")
          end
        end

        # The token kept for one authorization server, made the token in use
        # again. Only a record that says it belongs to that very server is
        # adopted, and one this client retired stays retired.
        # @param issuer [String, nil] the authorization server in use
        # @return [Token, nil]
        def token_kept_for_issuer(issuer)
          key = client_registration_key(issuer)
          return nil if key == server_url

          kept = begin
            normalize_record(storage.get_token(key), Token)
          rescue StandardError => e
            logger.debug("The OAuth token under #{key.inspect} could not be read (#{e.class})")
            nil
          end
          return nil unless token_bytes?(kept) && record_bound_to?(kept, issuer) && !retired_token?(kept)

          kept
        end

        # Forget the token kept for one authorization server.
        # @param issuer [String, nil]
        # @return [void]
        def forget_token_of_issuer(issuer)
          key = client_registration_key(issuer)
          return if key == server_url

          begin
            storage.respond_to?(:delete_token) ? storage.delete_token(key) : storage.set_token(key, nil)
          rescue StandardError => e
            logger.debug("The retired OAuth token could not be removed from #{key.inspect} (#{e.class})")
            mark_kept_token_retired(key)
          end
        end

        # A copy the backend refuses to delete is re-stored as retired, exactly
        # as the slot in use is: a provider built after a restart holds no
        # in-process retirement marker, so every copy in storage has to say
        # for itself that it was retired, or it would be adopted as live.
        # @param key [String] the per-authorization-server key of the copy
        # @return [void]
        def mark_kept_token_retired(key)
          kept = normalize_record(storage.get_token(key), Token)
          return unless kept.respond_to?(:with_issuer) && !kept.retired?

          storage.set_token(key, kept.with_issuer(Token::RETIRED_ISSUER))
        rescue StandardError => e
          logger.debug("The retired OAuth token under #{key.inspect} could not be marked retired (#{e.class})")
        end

        # @return [Token, nil]
        def stored_token
          token = normalize_record(storage.get_token(server_url), Token)
          # A backend without delete_token is asked to store nil, and one that
          # persists plain hashes writes `nil.to_h` — `{}`. Read back that is a
          # record without token bytes, whose header would be a bare "Bearer "
          # attributed to whatever authorization server is current now. It is
          # not a token: it is the absence storage meant to express. The same
          # backend can read back any other JSON type, or bytes no header can
          # carry, in EVERY field the token presents: a token_type that is not a
          # string crashes `capitalize`, and one carrying CR/LF makes the
          # `Authorization` value two header lines. A record that cannot be
          # presented is not a token either, so the read path is as strict as
          # the wire path.
          return nil if token.respond_to?(:access_token) && !token_bytes?(token)

          token
        end

        # Persist a token the authorization server just issued. Opaque tokens
        # are unique only within an issuer, so a new server may legitimately
        # issue the same bytes as a token retired at the previous one: the
        # fresh, issuer-bound token is never mistaken for the retired one.
        # @param token [Token]
        # @return [void]
        def store_token(token)
          storage.set_token(server_url, token)
          # Only a persisted replacement lifts the marker: if the write failed,
          # the stale record still in storage stays retired.
          @retired_tokens&.delete(retirement_key(token, nil)) if token.respond_to?(:access_token)
          # Kept under its own authorization server's key too, so a later
          # return to that server finds it (MCP 2026-07-28 keeps tokens per
          # authorization server).
          preserve_token(token)
        end

        # @param refreshed [Token, nil] the token a refresh was made with
        # @return [Boolean] whether it is still the token in use (a refresh made
        #   with no token to compare, as from a direct call, is not judged)
        def refreshed_token_in_use?(refreshed)
          return true unless refreshed.respond_to?(:access_token)

          current = stored_token_or_nil
          return false unless current.respond_to?(:access_token) && !retired_token?(current)

          same_token?(current, refreshed)
        end

        # @return [Boolean] whether two records carry the same token
        def same_token?(one, other)
          one.access_token == other.access_token && one.refresh_token == other.refresh_token
        end

        # @param token [Token, nil] the token in use
        # @return [Token, nil] the token when it can be presented now
        def presentable_token(token)
          return nil unless token && !token.expired? && token_for_current_issuer?(token)

          token
        end

        # Whether a token was retired in this process: a bound token when its
        # bytes were retired for its issuer, an unbound one when its bytes
        # were retired for any issuer (it cannot say which one it came from).
        # @param token [Token]
        # @return [Boolean]
        def retired_token?(token)
          return true if token.respond_to?(:retired?) && token.retired?
          return false unless token.respond_to?(:access_token) && @retired_tokens

          issuer = token.respond_to?(:issuer) ? token.issuer : nil
          return @retired_tokens.key?([issuer, token.access_token]) if issuer

          @retired_tokens.keys.any? { |_issuer, bytes| bytes == token.access_token }
        end

        # The in-process retirement marker of a token: its bytes together with
        # the issuer they were retired for (the recorded issuer, else the
        # issuer the token was bound to at retirement).
        # @param token [Token]
        # @param bind_to [String, nil]
        # @return [Array(String, String)]
        def retirement_key(token, bind_to)
          issuer = token.respond_to?(:issuer) ? token.issuer : nil
          [issuer || bind_to || Token::RETIRED_ISSUER, token.access_token]
        end

        # Whether a stored token belongs to the authorization server currently
        # known for this resource. While that server is unknown (no cached
        # metadata) nothing is presented: the next challenge discovers it.
        # @param token [Token]
        # @return [Boolean]
        def token_for_current_issuer?(token)
          return false if retired_token?(token)
          return true unless token.respond_to?(:issuer)

          current = current_issuer_for_tokens
          !current.nil? && current == token.issuer
        end

        # The authorization server tokens are judged against: a validated
        # challenge received since the metadata was cached is authoritative
        # (discovery treats it so), else the cached metadata's issuer.
        # @return [String, nil]
        def current_issuer_for_tokens
          # A challenge we REFUSED said the cached authorization server is no
          # longer the right one, and discovery fails closed on that latch. The
          # request path must fail closed too: presenting the cached bearer would
          # undo the rejection exactly as falling back to the cache would.
          return nil if @challenge_error

          advertised = Array(@challenge_resource_metadata&.authorization_servers).first
          return advertised if advertised.is_a?(String)
          # An unresolved challenge URL means the current server is unknown.
          return nil if @challenge_metadata_url

          stored_server_metadata&.issuer
        end

        # A token persisted before issuers were recorded was obtained from the
        # authorization server cached alongside it (a server change always
        # retires or binds the token first), so it is bound to that server on
        # first use; while no server is known it is not presented.
        # @param token [Token]
        # @return [Token, nil] the bound token, or nil when it cannot be bound yet
        def bind_token_issuer(token)
          return token unless token.respond_to?(:issuer) && token.issuer.nil? && token.respond_to?(:with_issuer)
          # A refused challenge says the cached server is no longer current, so
          # it cannot attribute an unbound token either.
          return nil if @challenge_error

          current = stored_server_metadata&.issuer
          return nil unless current

          bound = token.with_issuer(current)
          begin
            storage.set_token(server_url, bound)
          rescue StandardError => e
            logger.debug("The stored OAuth token could not be re-stored with its issuer (#{e.class})")
          end
          bound
        end
      end
    end
  end
end
