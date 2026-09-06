# frozen_string_literal: true

module MCPClient
  module Auth
    class OAuthProvider
      # How an authorization or registration request decides what scope to ask
      # for: the MCP scope SELECTION strategy picks what the request needs, and
      # the 2026-07-28 step-up rule adds back what this client has already
      # asked for or been granted. Mixed into {MCPClient::Auth::OAuthProvider};
      # every method is private there.
      module ScopeSelection
        private

        # Resolve the scope for authorization/registration requests: the MCP
        # scope SELECTION strategy picks what this request needs (see
        # {#selected_scope}), and the 2026-07-28 step-up rule adds back what has
        # already been asked for (see {#accumulated_scope}).
        # @return [String, nil]
        def resolved_scope
          accumulated_scope(selected_scope)
        end

        # What this request needs, by the MCP 2025-11-25 scope selection
        # strategy: the challenge's scope parameter is authoritative; then an
        # explicitly configured scope (:all resolves to the AS-advertised scope
        # list); then the Protected Resource Metadata's scopes_supported;
        # otherwise no scope at all.
        # @return [String, nil]
        def selected_scope
          return @challenge_scope if @challenge_scope && !@challenge_scope.empty?

          if scope == :all
            all_scopes = supported_scopes
            return all_scopes.join(' ') unless all_scopes.empty?
          elsif scope
            return scope
          end

          prm = @challenge_resource_metadata || @resource_metadata
          prm_scopes = advertised_scopes(prm&.scopes_supported)
          return prm_scopes.join(' ') unless prm_scopes.empty?

          nil
        end

        # MCP 2026-07-28 "Step-Up Authorization Flow", step 2: "Determine
        # required scopes by computing the union of the client's previously
        # requested scope set and the scopes from the current challenge. This
        # ensures previously granted permissions are preserved when servers
        # emit per-operation scope challenges." A challenge is authoritative for
        # what the CURRENT operation needs, not for what the client already had:
        # re-authorizing with the challenge's scope alone trades the permissions
        # every other operation depends on for the one being retried, and the
        # next operation challenges again.
        # @param selected [String, nil] the scope this request selects on its own
        # @return [String, nil] the union, or nil when no scope is to be sent
        def accumulated_scope(selected)
          scopes = (previously_requested_scopes + selected.to_s.split).uniq
          scopes.empty? ? nil : scopes.join(' ')
        end

        # "The client's previously requested scope set". Three things say what
        # this client already asked for, and a step-up that consulted only the
        # first would trade away permissions:
        #
        # * the last authorization request this provider made — in-process, and
        #   gone the moment the process restarts or the host builds another
        #   provider;
        # * the scope the host configured, which is what this client asks for
        #   whenever a challenge is not overriding it;
        # * the scope of the token in hand, which is what the authorization
        #   server actually granted (RFC 6749 Section 5.1) and is the only one
        #   of the three that survives a restart.
        #
        # The granted set counts only while the token belongs to the
        # authorization server in use: what one server granted is not a
        # permission another one ever gave, and asking B for A's scopes is at
        # best a rejected request. The in-process set is dropped for the same
        # reason when the authorization server changes, and with the rest of
        # the per-server state when the provider is retargeted.
        #
        # The configured scope counts only once this client has actually asked
        # for something or holds a grant. The rule preserves PREVIOUSLY
        # REQUESTED permissions; on a first authorization there are none, and
        # the challenge is authoritative for what the operation needs (MCP
        # 2026-07-28 scope selection). Adding the configured set there would
        # widen the very first request beyond what was challenged for — with
        # `scope: :all`, to everything the authorization server advertises.
        # @return [Array<String>]
        def previously_requested_scopes
          asked = @requested_scope.to_s.split
          granted = granted_scopes
          return (asked + granted).uniq if asked.empty? && granted.empty?

          (asked + configured_scopes + granted).uniq
        end

        # The scope the host configured, as a list.
        # @return [Array<String>]
        def configured_scopes
          return supported_scopes if scope == :all
          return [] unless scope.is_a?(String)

          scope.split
        end

        # The scope the authorization server in use granted the token in hand.
        # A token of another authorization server — or one this client
        # retired — grants nothing here.
        # @return [Array<String>]
        def granted_scopes
          token = stored_token_or_nil
          return [] unless token.respond_to?(:scope) && token.scope.is_a?(String)
          return [] unless token_for_current_issuer?(token) || bindable_to_current_issuer?(token)

          token.scope.split
        end

        # A scopes_supported value as a scope list: RFC 8414 Section 2 and RFC
        # 9728 Section 2 both make it an array of strings, and a document that
        # breaks that is refused on the wire — but a record read back from a
        # storage backend that persists plain hashes is not, and `"a b".join`
        # is a NoMethodError out of the flow.
        # @param scopes [Object, nil] the advertised value
        # @return [Array<String>] the scopes, or none
        def advertised_scopes(scopes)
          return [] unless scopes.is_a?(Array)

          scopes.grep(String)
        end
      end
    end
  end
end
