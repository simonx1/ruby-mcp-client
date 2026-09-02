# frozen_string_literal: true

require 'uri'

module MCPClient
  module Auth
    class OAuthProvider
      # Type checks for the two peer-controlled JSON bodies an authorization
      # server answers a request with: the token response of RFC 6749
      # Section 5.1 and the client registration response of RFC 7591
      # Section 3.2.1 (whose client metadata fields keep the types RFC 7591
      # Section 2 gives them).
      #
      # Both bodies are read field by field and every field ends up somewhere
      # that assumes its RFC type: `token_type` is capitalized into an
      # `Authorization` header, `expires_in` is added to a `Time`,
      # `redirect_uris` is asked for its first element,
      # `client_secret_expires_at` is compared with a Unix timestamp. A peer
      # that answers with the right names and the wrong JSON types would
      # therefore crash the client with a `NoMethodError` or a `TypeError`
      # deep inside the flow — sometimes only after a still-valid token had
      # been overwritten. A response whose fields are not of their RFC types
      # is a protocol error and is refused as a whole, exactly as a token
      # response without an access token is: no partial acceptance, no
      # coercion of whatever JSON arrived.
      #
      # Mixed into OAuthProvider.
      module ResponseValidation
        # Where the token response's field types are specified.
        TOKEN_RESPONSE_REFERENCE = 'RFC 6749 Section 5.1'

        # Where the registration response's field types are specified.
        REGISTRATION_RESPONSE_REFERENCE = 'RFC 7591 Section 3.2.1'

        # The fields of a successful token response and the types RFC 6749
        # Section 5.1 gives them. access_token and token_type are REQUIRED and
        # end up in an `Authorization` header, so they must be bytes a header
        # can carry: an empty string is no more usable than a JSON array, and
        # a CR or an LF would not be part of the value at all but the start of
        # another header line. refresh_token is OPTIONAL but is a credential
        # too: bytes or nothing, because "" would be persisted over the
        # refresh token the client already holds. scope is free text.
        # Fields the RFC does not name are ignored: an authorization server
        # may return anything else it likes.
        TOKEN_RESPONSE_FIELDS = {
          'access_token' => :header_value,
          'token_type' => :header_value,
          'expires_in' => :integer,
          'refresh_token' => :non_empty_string,
          'scope' => :string
        }.freeze

        # The fields of a client registration response and their types: the
        # registration-specific fields of RFC 7591 Section 3.2.1 followed by
        # the client metadata of Section 2 that the server echoes back.
        REGISTRATION_RESPONSE_FIELDS = {
          'client_id' => :non_empty_string,
          'client_secret' => :string,
          'client_id_issued_at' => :integer,
          'client_secret_expires_at' => :integer,
          'redirect_uris' => :redirect_uri_array,
          'token_endpoint_auth_method' => :string,
          'grant_types' => :string_array,
          'response_types' => :string_array,
          'scope' => :string,
          'client_name' => :string,
          'client_uri' => :string,
          'logo_uri' => :string,
          'tos_uri' => :string,
          'policy_uri' => :string,
          'contacts' => :string_array,
          'application_type' => :string
        }.freeze

        # How each type reads in a failure message.
        TYPE_DESCRIPTIONS = {
          string: 'a string',
          non_empty_string: 'a non-empty string',
          header_value: 'a non-empty string of bytes an HTTP header can carry',
          integer: 'an integer',
          string_array: 'an array of strings',
          redirect_uri_array: 'an array of usable redirect URIs'
        }.freeze

        # Bytes no HTTP header field value may carry: the C0 controls (CR and
        # LF above all, which would end the header line and start one of the
        # peer's choosing) and DEL. RFC 6749 Appendix A is stricter still —
        # an access token is 1*VSCHAR — but obs-text is at least transported,
        # while a control byte is either refused by the HTTP stack or splits
        # the request.
        HEADER_UNSAFE_BYTE = ->(byte) { byte < 0x20 || byte == 0x7F }

        private

        # Why a parsed token endpoint response is not a credential, if it is
        # not one. The body is peer-controlled JSON of any shape: `200 []` and
        # `200 null` parse to an Array and to nil, which cannot be asked for a
        # member at all, so the shape is established before any value is read.
        # @param data [Object, nil] the parsed JSON body
        # @return [String, nil] the reason, or nil when the response is usable
        def token_response_error(data)
          unless issued_access_token?(data)
            return "the token response carries no access_token (#{TOKEN_RESPONSE_REFERENCE})"
          end

          mistyped_field_error(data, TOKEN_RESPONSE_FIELDS, 'token', TOKEN_RESPONSE_REFERENCE)
        end

        # Why a parsed client registration response registers no client, if it
        # registers none.
        # @param data [Object, nil] the parsed JSON body
        # @return [String, nil] the reason, or nil when the response is usable
        def registration_response_error(data)
          unless registered_client?(data)
            return "the registration response carries no client_id (#{REGISTRATION_RESPONSE_REFERENCE})"
          end

          mistyped_field_error(data, REGISTRATION_RESPONSE_FIELDS, 'registration',
                               REGISTRATION_RESPONSE_REFERENCE)
        end

        # The first field of a response body that is present and not of the
        # type its RFC gives it. A field that is absent (or JSON null) is not
        # mistyped: the optional ones may be omitted, and the required ones
        # are checked by name before this runs.
        # @param data [Hash] the parsed JSON body
        # @param fields [Hash{String => Symbol}] field name to expected type
        # @param label [String] what the body is, for the message
        # @param reference [String] the RFC section the types come from
        # @return [String, nil]
        def mistyped_field_error(data, fields, label, reference)
          fields.each do |field, type|
            value = data[field]
            next if value.nil? || value_of_type?(value, type)

            return "the #{label} response's #{field} is not #{TYPE_DESCRIPTIONS[type]} (#{reference})"
          end
          nil
        end

        # @param value [Object] a value read from a response body
        # @param type [Symbol] one of the keys of TYPE_DESCRIPTIONS
        # @return [Boolean]
        def value_of_type?(value, type)
          case type
          when :string then value.is_a?(String)
          when :non_empty_string then non_empty_string?(value)
          when :header_value then header_value_bytes?(value)
          # `true` and `false` are not Integers, so booleans are rejected here.
          when :integer then value.is_a?(Integer)
          when :string_array then value.is_a?(Array) && value.all?(String)
          when :redirect_uri_array then value.is_a?(Array) && value.all? { |uri| redirect_uri_bytes?(uri) }
          else false
          end
        end

        # Whether a token record can be presented at all. Both fields
        # {MCPClient::Auth::Token#to_header} builds the `Authorization` header
        # out of are checked, not just the access token: a record whose
        # access_token is absent, empty or of any other type is never a
        # credential — its header would be a bare "Bearer " or, worse,
        # `Bearer ["x"]`, a to_s of whatever JSON arrived, attributed to
        # whatever authorization server is current — and a token_type that is
        # not a string crashes `capitalize`, while one carrying CR or LF makes
        # the header value two header lines. Storage answers with whatever it
        # was given, so this is asked wherever a token is read, issued or
        # applied, not only of what came off the wire.
        # @param token [Object, nil] a token record
        # @return [Boolean] whether it carries bytes an Authorization header can present
        def token_bytes?(token)
          return false unless token.respond_to?(:access_token) && access_token_bytes?(token.access_token)

          token.respond_to?(:token_type) && header_value_bytes?(token.token_type)
        end

        # The same question about a parsed token endpoint response body.
        # @param data [Object, nil] the parsed JSON body
        # @return [Boolean]
        def issued_access_token?(data)
          data.is_a?(Hash) && access_token_bytes?(data['access_token'])
        end

        # RFC 7591 Section 3.2.1 makes client_id REQUIRED in a registration
        # response, and it is a string: it goes into the authorization URL and
        # into every token request. A response without usable bytes has
        # registered nothing — accepting it sends the user to the
        # authorization endpoint with an empty (or a `to_s`-mangled)
        # client_id, and the flow only fails on the way back, after the
        # browser has already been opened.
        # @param data [Object, nil] the parsed JSON registration response
        # @return [Boolean]
        def registered_client?(data)
          data.is_a?(Hash) && client_id_bytes?(data['client_id'])
        end

        # @param value [Object, nil] a candidate access token
        # @return [Boolean] whether it is token bytes an Authorization header can carry
        def access_token_bytes?(value)
          header_value_bytes?(value)
        end

        # @param value [Object, nil] a candidate header field value
        # @return [Boolean] whether it is a non-empty string an HTTP header can carry
        def header_value_bytes?(value)
          non_empty_string?(value) && value.each_byte.none?(&HEADER_UNSAFE_BYTE)
        end

        # A registered redirect URI is asked for its `first` and put into the
        # authorization URL the browser is sent to. An empty string is an
        # array element of the right JSON type and no redirect URI at all: it
        # opens the browser with `redirect_uri=`, and the authorization server
        # rejects the request the user was just sent into. So an array of
        # strings registers redirect URIs only when every element is one:
        # absolute, and parseable as a URI.
        # @param value [Object, nil] a candidate redirect URI
        # @return [Boolean]
        def redirect_uri_bytes?(value)
          return false unless non_empty_string?(value)

          !URI.parse(value).scheme.to_s.empty?
        rescue URI::InvalidURIError
          false
        end

        # @param value [Object, nil] a candidate client id
        # @return [Boolean] whether it is a non-empty string of client id bytes
        def client_id_bytes?(value)
          non_empty_string?(value)
        end

        # @param value [Object, nil]
        # @return [Boolean] whether it is a String with at least one character
        def non_empty_string?(value)
          value.is_a?(String) && !value.empty?
        end
      end
    end
  end
end
