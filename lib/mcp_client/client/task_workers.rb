# frozen_string_literal: true

require_relative '../json_rpc_common'
require_relative '../errors'

module MCPClient
  class Client
    # The workers that carry task requests through a transport which takes no
    # per-request timeout (see TaskSupport#capped_task_rpc), and the wire
    # spelling of what any transport hands up.
    module TaskWorkers
      # How many requests may be left hanging on one transport that takes no
      # per-request timeout (see #capped_task_rpc) before the next distinct
      # one is refused rather than started beside them.
      MAX_PENDING_TASK_REQUESTS = 4

      private

      # A task payload as it was on the wire: a transport of the host's own
      # (or a JSON middleware) may hand hashes up with Symbol keys, and the
      # shape checks and the bookkeeping read the wire's String keys — as
      # the multi round-trip resolver already does for its results.
      # @param answer [Object] a JSON-RPC result
      # @return [Object] the same value with String keys throughout
      def wire_keyed(answer)
        MCPClient::JsonRpcCommon.restore_wire_keys(answer)
      end

      # The worker running a request on a transport without a timeout: the
      # one still hanging (or just back) for this very request, else a new
      # one — unless the transport already has the cap's worth of others
      # hanging. Requests that came back while nobody was waiting for them
      # are forgotten here, except this one's.
      # @param key [Array] what identifies the request (method, params, pins)
      # @return [Thread]
      def pending_task_request(srv, key)
        pending_task_requests_mutex.synchronize do
          pending = pending_task_requests(srv)
          pending.delete_if { |other, worker| other != key && !worker.alive? }
          return pending[key] if pending[key]

          if pending.size >= MAX_PENDING_TASK_REQUESTS
            raise MCPClient::Errors::TransportError,
                  "#{srv.name} has #{pending.size} task requests unanswered; not sending #{key[0]} beside them"
          end

          pending[key] = yield
        end
      end

      # @return [Hash{Array => Thread}] this transport's requests still hanging
      def pending_task_requests(srv)
        @pending_task_requests ||= {}.compare_by_identity
        @pending_task_requests[srv] ||= {}
      end

      # @return [Mutex]
      def pending_task_requests_mutex
        @pending_task_requests_mutex ||= Mutex.new
      end
    end
  end
end
