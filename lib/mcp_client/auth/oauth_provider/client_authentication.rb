# frozen_string_literal: true

require 'base64'
require 'uri'

module MCPClient
  module Auth
    class OAuthProvider
      # How this client authenticates at the token endpoint.
      #
      # A confidential client — one the authorization server issued a
      # `client_secret` to — must present that secret with every token
      # request, and RFC 7591 Section 2 says how: "if unspecified or omitted,
      # the default is `client_secret_basic`". This client used to send the
      # secret only for `client_secret_post` and to record an omitted method
      # as `none`, which is the one combination that never authenticates: a
      # registration that issued a secret and named no method produced a
      # record whose secret was never sent, and every token request went out
      # as an unauthenticated client for an authorization server that expects
      # HTTP Basic.
      #
      # So the method the authorization server registered decides, defaulting
      # as the RFC does:
      #
      # * `client_secret_basic` — the credentials go in an `Authorization:
      #   Basic` header, form-urlencoded before they are base64'd (RFC 6749
      #   Section 2.3.1), never in the body;
      # * `client_secret_post` — in the request body, as before;
      # * `none` (a public client, or no secret at all) — nothing is sent;
      # * anything else (`private_key_jwt`, `client_secret_jwt`, a method a
      #   future RFC adds) — this client cannot produce that assertion, so it
      #   sends no credentials and says so, rather than guessing with the
      #   secret in a header the server did not ask for.
      #
      # Mixed into OAuthProvider.
      module ClientAuthentication
        # RFC 7591 Section 2: the `token_endpoint_auth_method` a registration
        # response that names none is read as.
        DEFAULT_TOKEN_ENDPOINT_AUTH_METHOD = 'client_secret_basic'

        # The method a public client declares: no credentials are sent.
        NO_CLIENT_AUTHENTICATION = 'none'

        private

        # The `token_endpoint_auth_method` to record for a registration
        # response. RFC 7591 Section 2's default applies to a client the
        # server issued a secret to; a registration without one is the public
        # client this library asks to be.
        # @param data [Hash] the parsed registration response
        # @return [String]
        def registered_auth_method(data)
          method = data['token_endpoint_auth_method']
          return method if method.is_a?(String) && !method.empty?

          client_secret_bytes?(data['client_secret']) ? DEFAULT_TOKEN_ENDPOINT_AUTH_METHOD : NO_CLIENT_AUTHENTICATION
        end

        # Add this client's credentials to a token request the way the
        # authorization server registered them.
        # @param params [Hash] the form parameters, extended in place for client_secret_post
        # @param client_info [ClientInfo] the credentials to present
        # @return [String, nil] the `Authorization` header value to send, if any
        def apply_client_credentials!(params, client_info)
          method = token_endpoint_auth_method_for(client_info)
          case method
          when nil, NO_CLIENT_AUTHENTICATION
            nil
          when 'client_secret_post'
            params[:client_secret] = client_info.client_secret
            nil
          when DEFAULT_TOKEN_ENDPOINT_AUTH_METHOD
            basic_authorization_header(client_info.client_id, client_info.client_secret)
          else
            logger.warn('The authorization server registered token_endpoint_auth_method ' \
                        "#{safe_error_text(method.to_s).inspect}, which this client cannot present; " \
                        'the token request is made without client authentication')
            nil
          end
        end

        # The method to authenticate these credentials with. A client without
        # a secret authenticates with nothing whatever its metadata says; a
        # client WITH one falls back to RFC 7591's default, which also covers
        # a record persisted before this client read the field (stored as
        # `none` alongside a secret, a combination that authenticates
        # nowhere).
        # @param client_info [ClientInfo]
        # @return [String, nil] the method, or nil when nothing is to be sent
        def token_endpoint_auth_method_for(client_info)
          return nil unless client_secret_bytes?(client_info.client_secret)

          method = client_info.metadata.token_endpoint_auth_method
          return DEFAULT_TOKEN_ENDPOINT_AUTH_METHOD unless method.is_a?(String) && !method.empty?
          return DEFAULT_TOKEN_ENDPOINT_AUTH_METHOD if method == NO_CLIENT_AUTHENTICATION

          method
        end

        # RFC 6749 Section 2.3.1: the client identifier and secret are encoded
        # with `application/x-www-form-urlencoded` and then, joined by a
        # single colon, base64-encoded — so a `:` or a space in either does
        # not shift the boundary the server splits on.
        # @param client_id [String]
        # @param client_secret [String]
        # @return [String] the `Authorization` header value
        def basic_authorization_header(client_id, client_secret)
          credentials = "#{URI.encode_www_form_component(client_id.to_s)}:" \
                        "#{URI.encode_www_form_component(client_secret.to_s)}"
          "Basic #{Base64.strict_encode64(credentials)}"
        end

        # @param value [Object, nil] a candidate client secret
        # @return [Boolean] whether it is a secret this client could present
        def client_secret_bytes?(value)
          value.is_a?(String) && !value.empty?
        end
      end
    end
  end
end
