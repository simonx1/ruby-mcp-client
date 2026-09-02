# frozen_string_literal: true

require 'ipaddr'

module MCPClient
  module Auth
    class OAuthProvider
      # WWW-Authenticate challenge handling for {OAuthProvider}: parsing the
      # challenge, fetching and validating the resource metadata it names,
      # retiring tokens of another authorization server, and the checks a
      # peer-advertised URL must pass. Mixed into OAuthProvider; every method
      # relies on its state.
      module ChallengeHandling
        # One decimal, octal or hexadecimal component of a numeric IPv4 spec.
        IPV4_COMPONENT = /\A(?:0x[0-9a-f]+|0[0-7]*|[1-9][0-9]*)\z/i

        # Handle 401 Unauthorized response (for server discovery)
        # @param response [Faraday::Response] HTTP response
        # @return [ResourceMetadata, nil] Resource metadata if found
        def handle_unauthorized_response(response)
          www_authenticate = response.headers['WWW-Authenticate'] || response.headers['www-authenticate']
          return nil unless www_authenticate

          # Challenge parameters are read from the Bearer challenge's own
          # segment only — never from the whole (possibly multi-challenge)
          # header — so parameters belonging to Basic or another scheme cannot
          # drive Bearer scope selection or resource metadata discovery. A
          # header without a Bearer challenge carries no usable Bearer params.
          bearer_params = bearer_challenge_segment(www_authenticate)

          # MCP 2025-11-25: "Clients MUST treat the scopes provided in the
          # challenge as authoritative for satisfying the current request" —
          # including resetting a previously challenged scope when the current
          # challenge carries none.
          url = extract_resource_metadata_url(www_authenticate)

          # The challenge header is peer-controlled input: validate the
          # advertised URL BEFORE storing, fetching, or recording any challenge
          # state, so a malicious challenge cannot pivot this host into requests
          # against internal services (SSRF) and cannot leave the provider
          # holding half of a rejected challenge.
          validate_peer_advertised_url!(url, 'resource metadata URL (from WWW-Authenticate challenge)') if url

          @challenge_scope = bearer_params && extract_challenge_param(bearer_params, 'scope')
          return nil unless url

          # Remember the advertised URL even if the fetch below fails, so a
          # later discovery retries it instead of probing well-known URIs the
          # challenge already superseded. The current header is the one to
          # honour: an earlier document, and an earlier refusal, are forgotten
          # before the fetch so a failed fetch leaves the flow waiting on this
          # URL rather than completing against stale state.
          @challenge_metadata_url = url
          @challenge_resource_metadata = nil
          @challenge_error = nil

          adopt_challenge_metadata(url)
        end

        # Fetch, validate and adopt the resource metadata a challenge named.
        # @param url [String] the advertised metadata URL
        # @return [ResourceMetadata]
        # @raise [MCPClient::Errors::ConnectionError] when the fetch fails or the document is refused
        def adopt_challenge_metadata(url)
          # This URL was explicitly advertised by the 401 challenge, so a 404 is a
          # misconfiguration to surface (strict), not a speculative miss to skip.
          metadata = fetch_resource_metadata(url, strict: true)
          # Metadata discovery would reject is refused now, whole: it neither
          # retires the token nor lingers as an authoritative challenge.
          reject_unacceptable_challenge!(metadata)
          # A validated challenge supersedes an earlier refused one.
          @challenge_error = nil
          # Reuse this challenge-advertised metadata during the subsequent OAuth
          # flow instead of re-deriving (and possibly missing) the well-known URL.
          @challenge_resource_metadata = metadata
          revoke_token_on_authorization_server_change(metadata)
          metadata
        end

        # A challenge whose metadata could not be fetched yet is retried before
        # any token is judged: until it resolves, the current authorization
        # server is unknown and nothing is presented.
        # @return [void]
        def resolve_pending_challenge
          return unless @challenge_metadata_url && @challenge_resource_metadata.nil?

          adopt_challenge_metadata(@challenge_metadata_url)
        rescue MCPClient::Errors::ConnectionError => e
          logger.debug("Challenge metadata still unresolved: #{e.message}")
        end

        # A challenge naming another authorization server than the one the
        # stored token came from retires that token at once: it is never
        # presented again, whatever the storage backend can do.
        # @param resource_metadata [ResourceMetadata]
        # @return [void]
        def revoke_token_on_authorization_server_change(resource_metadata)
          advertised = Array(resource_metadata&.authorization_servers).first
          known = stored_server_metadata&.issuer
          return unless advertised && known && advertised != known

          @authorization_server_switched = true
          # A token another provider sharing the storage already bound to the
          # advertised server is exactly the token to keep.
          return if record_bound_to?(stored_token_or_nil, advertised)

          logger.debug('The challenge names another authorization server; retiring the stored token')
          delete_token(bind_to: Token::RETIRED_ISSUER)
        end

        # Apply the checks discovery applies to challenge-advertised resource
        # metadata (resource identity, an acceptable authorization server URL)
        # before anything acts on it; a failing document refuses the whole
        # challenge (see {#reject_challenge!}).
        # @param resource_metadata [ResourceMetadata]
        # @return [void]
        # @raise [MCPClient::Errors::ConnectionError] when the challenge is refused
        def reject_unacceptable_challenge!(resource_metadata)
          begin
            validate_resource_matches!(resource_metadata)
          rescue MCPClient::Errors::ConnectionError => e
            reject_challenge!(e.message)
          end
          advertised = Array(resource_metadata.authorization_servers).first
          unless advertised
            reject_challenge!('Protected resource metadata does not advertise any authorization_servers')
          end

          validate_peer_advertised_url!(advertised, 'authorization server URL (from resource metadata)')
        end

        # Extract the protected-resource-metadata URL from a WWW-Authenticate header.
        # Per RFC 9728 the parameter is `resource_metadata`; a legacy `resource`
        # parameter is accepted as a fallback for older servers. Only the Bearer
        # challenge's own segment is consulted, so a parameter belonging to
        # another scheme's challenge can never drive discovery.
        # @param header [String] the WWW-Authenticate header value
        # @return [String, nil] the metadata URL if present
        def extract_resource_metadata_url(header)
          params = bearer_challenge_segment(header)
          return nil unless params

          # Auth-params may include optional whitespace around '=' (RFC 7235).
          # Quoted form: resource_metadata = "https://..."
          if (m = params.match(/resource_metadata\s*=\s*"([^"]+)"/))
            return m[1]
          end

          # Unquoted token form: resource_metadata = https://...
          if (m = params.match(/resource_metadata\s*=\s*([^,\s]+)/))
            return m[1]
          end

          # Legacy fallback: resource="https://..."
          params.match(/resource\s*=\s*"([^"]+)"/)&.captures&.first
        end

        # Extract the Bearer challenge's own parameter segment from a (possibly
        # multi-challenge) WWW-Authenticate header, so params belonging to other
        # schemes (e.g. `Basic resource_metadata="...", Bearer realm="x"`) are
        # never attributed to the Bearer challenge. Mirrors
        # HttpTransportBase#bearer_challenge_segment.
        # @param header [String, nil] the WWW-Authenticate header value
        # @return [String, nil] the Bearer challenge's parameters (possibly
        #   empty), or nil when the header has no Bearer challenge
        def bearer_challenge_segment(header)
          return nil unless header

          # Locate the Bearer scheme token only OUTSIDE quoted strings: a
          # quoted value such as realm="prefix Bearer x" must not anchor the
          # segment.
          masked = header.gsub(/"(?:\\.|[^"\\])*"/) { |q| "\"#{' ' * (q.length - 2)}\"" }
          match = masked.match(/(?:\A|[\s,])Bearer(?=[\s,]|\z)/i)
          return nil unless match

          header[match.end(0)..][AUTH_PARAMS_RUN]
        end

        # Extract an auth-param value from a WWW-Authenticate header
        # (quoted or unquoted form, optional whitespace around '=').
        # @param header [String] the WWW-Authenticate header value
        # @param name [String] the auth-param name
        # @return [String, nil] the parameter value if present
        def extract_challenge_param(header, name)
          if (m = header.match(/(?:^|[\s,])#{Regexp.escape(name)}\s*=\s*"([^"]*)"/i))
            return m[1]
          end

          header.match(/(?:^|[\s,])#{Regexp.escape(name)}\s*=\s*([^,\s]+)/i)&.captures&.first
        end

        private

        # Validate a URL that a peer advertised to us (a 401 challenge's
        # resource_metadata, or PRM authorization_servers).
        #
        # Stricter than enforce_https!, which exists for URLs the OPERATOR
        # configured and therefore tolerates plain-HTTP loopback for local
        # development. Applying that exception to peer-supplied input would
        # leave the reported SSRF intact against the most sensitive targets of
        # all — services listening only on localhost. The loopback exception is
        # honored here only when the configured MCP server is itself loopback,
        # i.e. the developer is already pointed at a local stack.
        #
        # A refusal of a CHALLENGE-advertised URL is recorded (latch: true) so a
        # later discovery fails closed instead of silently reusing cached
        # authorization-server metadata. A refusal of a document found by
        # speculative well-known discovery records nothing: there is no cache to
        # protect, and latching it would leave a server that is later fixed
        # unreachable for the life of this provider.
        #
        # NOTE: hostnames are checked literally. This does not resolve DNS, so a
        # public name that resolves to a private address is not caught here;
        # that needs resolution-time checking in the HTTP layer.
        # @param url [String] the peer-advertised URL
        # @param label [String] human-readable name for errors
        # @param latch [Boolean] whether a refusal is recorded as an authoritative
        #   challenge refusal (true for a 401 challenge, false for speculative
        #   well-known discovery, which must stay retryable)
        # @raise [MCPClient::Errors::ConnectionError] if the URL is not acceptable
        def validate_peer_advertised_url!(url, label, latch: true)
          uri = URI.parse(url)
          host = uri.hostname.to_s.downcase

          if uri.scheme != 'https' && !(uri.scheme == 'http' && local_development?)
            refuse_peer_url!("OAuth #{label} must use HTTPS: #{safe_error_text(url)}", latch: latch)
          end
          # An authority-less URL ('https:foo', 'https:///foo') has an acceptable
          # scheme and an empty host, so it would otherwise pass every check
          # below and be treated as a validated authorization server — enough to
          # retire the stored token before discovery can only fail.
          refuse_peer_url!("OAuth #{label} must name a host: #{safe_error_text(url)}", latch: latch) if host.empty?
          if local_address?(host) && !local_development?
            refuse_peer_url!("OAuth #{label} must not target a loopback or private address: #{safe_error_text(url)}",
                             latch: latch)
          end
        rescue URI::InvalidURIError
          refuse_peer_url!("OAuth #{label} is not a valid URL: #{safe_error_text(url)}", latch: latch)
        end

        # @param message [String] why the peer-advertised URL was refused
        # @param latch [Boolean] whether to record the refusal for later discovery
        # @raise [MCPClient::Errors::ConnectionError] always
        def refuse_peer_url!(message, latch:)
          reject_challenge!(message) if latch

          # A speculative document is not latched, but it is still refused: the
          # copy fetch_resource_metadata kept for scope resolution must go too,
          # or its scopes_supported would be sent in the registration and
          # authorization requests of a flow that discarded the document.
          @resource_metadata = nil
          raise MCPClient::Errors::ConnectionError, message
        end

        # @return [Boolean] whether the resource metadata being acted on was
        #   advertised by a 401 challenge (authoritative) rather than found by
        #   speculative well-known discovery
        def challenge_advertised_metadata?
          !(@challenge_resource_metadata.nil? && @challenge_metadata_url.nil?)
        end

        # @param message [String] why the challenge was refused
        # @raise [MCPClient::Errors::ConnectionError] always
        def reject_challenge!(message)
          # Drop every scrap of the refused challenge so nothing half-applied
          # survives, and remember why for the next discovery attempt.
          @challenge_scope = nil
          @challenge_metadata_url = nil
          @challenge_resource_metadata = nil
          @resource_metadata = nil
          @challenge_error = message
          raise MCPClient::Errors::ConnectionError, message
        end

        # @return [Boolean] whether the configured MCP server is itself local,
        #   in which case local discovery targets are expected
        def local_development?
          local_address?(URI.parse(server_url).hostname.to_s.downcase)
        rescue URI::InvalidURIError
          false
        end

        # @param host [String] a downcased hostname
        # @return [Boolean] whether it names a loopback, private or link-local address
        def local_address?(host)
          host = host.to_s.delete_prefix('[').delete_suffix(']')
          return true if host == 'localhost'
          return true if host.end_with?('.localhost', '.local', '.internal')

          local_ip?(host)
        end

        # Classify a literal address semantically rather than by spelling: a
        # prefix list misses the forms IPv6 permits for the very ranges it
        # means to reject ('::ffff:169.254.169.254' for the link-local metadata
        # endpoint, '0:0:0:0:0:0:0:1' for loopback), so parse the host and ask
        # IPAddr. IPv4-mapped and IPv4-compatible addresses are folded to their
        # IPv4 form first, so one set of range checks covers both families.
        # @param host [String] a hostname with any brackets already stripped
        # @return [Boolean] whether it is a literal address in a local range
        def local_ip?(host)
          ip = parse_address(host)
          return false unless ip

          ip = ip.native if ip.ipv6? && (ip.ipv4_mapped? || ip.ipv4_compat?)
          # 0.0.0.0 / :: name "this host" and are neither loopback nor private
          # to IPAddr, but reach local services just the same.
          return true if ip.to_i.zero?

          ip.loopback? || ip.link_local? || ip.private?
        end

        # @param host [String] a hostname
        # @return [IPAddr, nil] the address it names, or nil when it is a name
        def parse_address(host)
          IPAddr.new(host)
        rescue ArgumentError # IPAddr::Error included
          # IPAddr only accepts dotted quads, but the resolver (inet_aton) also
          # accepts shorthand and alternate radixes — '127.1', '0177.0.0.1',
          # '0x7f.0.0.1' and '2130706433' all reach 127.0.0.1 — so a check that
          # stopped at IPAddr would wave those straight through.
          shorthand_ipv4(host)
        end

        # @param host [String] a hostname
        # @return [IPAddr, nil] the address inet_aton would read, when the host
        #   is a numeric IPv4 spec IPAddr itself rejects
        def shorthand_ipv4(host)
          parts = host.split('.', -1)
          return nil unless (1..4).cover?(parts.size) && parts.all? { |part| part.match?(IPV4_COMPONENT) }

          values = parts.map { |part| Integer(part, ipv4_component_base(part)) }
          # inet_aton: the last component fills every byte the earlier ones left.
          last = values.pop
          return nil if last >= (1 << (8 * (4 - values.size))) || values.any? { |value| value > 255 }

          IPAddr.new(values.each_with_index.sum { |value, i| value << (8 * (3 - i)) } + last, Socket::AF_INET)
        rescue ArgumentError
          nil
        end

        # @param part [String] one component of a numeric IPv4 spec
        # @return [Integer] its radix (leading '0x' hex, leading '0' octal, else decimal)
        def ipv4_component_base(part)
          return 16 if part.downcase.start_with?('0x')

          part.start_with?('0') ? 8 : 10
        end
      end
    end
  end
end
