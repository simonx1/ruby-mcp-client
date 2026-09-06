# frozen_string_literal: true

module MCPClient
  module Auth
    class OAuthProvider
      # The authorization requests still pending for one MCP server, as every
      # provider sharing the storage sees them: the pending-flow slot is read
      # back before a code exchange is accepted, and emptied when the resource
      # is known to have left the authorization server the requests were made
      # with. Mixed into {OAuthProvider}; every method is private there.
      module PendingRequests
        private

        # Whether the authorization request a response answers is still
        # pending: the record in the pending slot was made with the same
        # authorization server — this request's own, or a newer request's at
        # that server (an older completion does not lose to a newer start
        # there). The slot is the one thing every provider reads back before
        # it accepts a response, so a record marked as ended is how a
        # validated change of authorization server reaches a provider whose
        # own view of the server never changed.
        # @param pkce [PKCE] the per-request record the exchange was made with
        # @return [Boolean]
        def request_still_pending?(pkce)
          pending = stored_pkce
          pending.respond_to?(:issuer) && pending.issuer == pkce.issuer
        end

        # End the authorization request pending with an authorization server
        # this resource is known to have left: its code exchange, arriving
        # later at any provider sharing the storage, would otherwise be judged
        # against the server it went to and store that server's token as the
        # resource's. The record is kept, marked ({PKCE::ENDED_ISSUER}) rather
        # than deleted, so a late callback is refused for the reason that
        # ended it — and on a backend that cannot delete as on any other.
        # @param issuer [String] the authorization server the resource left
        # @return [void]
        def end_pending_requests_of(issuer)
          with_authorization_state_lock do
            pending = stored_pkce
            return unless pending.respond_to?(:issuer) && pending.issuer == issuer

            storage.set_pkce(server_url, PKCE.from_h(pending.to_h.merge(issuer: PKCE::ENDED_ISSUER)))
          end
        rescue StandardError => e
          logger.debug("The pending authorization request could not be ended: #{e.class}")
        end
      end
    end
  end
end
