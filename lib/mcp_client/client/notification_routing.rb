# frozen_string_literal: true

module MCPClient
  class Client
    # What the client does with a notification a transport delivers: the
    # caches it drops, the host callbacks it runs, and how a transport's
    # notifications are hooked up in the first place. A listener is host
    # code, run after the client's own bookkeeping; its failures are the
    # transport's to isolate.
    module NotificationRouting
      private

      # Process incoming JSON-RPC notifications with default handlers
      # @param server [MCPClient::ServerBase] the server that emitted the notification
      # @param method [String] JSON-RPC notification method
      # @param params [Hash] parameters for the notification
      # @return [void]
      # Wire this client's own notification processing and the host's listeners
      # onto the transport.
      #
      # The cache invalidation goes on the transport's own invalidation hook,
      # which runs *before* a notification is delivered to a subscription's
      # listeners — so a listener reacting to a `list_changed` notification
      # re-fetches instead of reading the entry the notification just
      # invalidated. Everything else this client does with a notification is host
      # code or leads to it (logging, progress callbacks, task status), and stays
      # on the callback that runs last, behind the delivery. A transport that
      # emits no such hook — a host-supplied adapter written against the older
      # interface, say — keeps the invalidation on `on_notification`, ahead of
      # everything else there: it routes no subscriptions, so there is no
      # delivery for it to be ahead of.
      #
      # Which of the two it is cannot be answered by whether the transport *has*
      # the hook: every {MCPClient::ServerBase} subclass inherits it, so the
      # answer was yes for every custom adapter as well, and one that fans its
      # notifications out through `@notification_callback` alone — exactly what
      # the interface used to be — silently stopped invalidating anything. The
      # question is whether the hook actually *ran* for the notification in
      # hand, and the hook answers it itself: every path that emits it does so
      # immediately before the host callback and on the same thread
      # ({MCPClient::JsonRpcCommon#notify_cache_invalidation}), so a callback
      # that arrives without that mark is one nothing invalidated for. Having
      # the hook still decides whether one is *registered* — a host may supply
      # an object that is no ServerBase at all — but no longer decides who
      # invalidates.
      # @param server [MCPClient::ServerBase] the server to wire
      # @return [void]
      def register_notification_handlers(server)
        if server.class.method_defined?(:on_cache_invalidation)
          server.on_cache_invalidation do |method, _params|
            invalidate_caches_for_notification(server, method)
            Thread.current[CACHE_INVALIDATION_MARK] = [server, method]
          end
        end
        server.on_notification do |method, params|
          mark = Thread.current[CACHE_INVALIDATION_MARK]
          Thread.current[CACHE_INVALIDATION_MARK] = nil
          invalidate_caches_for_notification(server, method) unless mark_covers?(mark, server, method)
          # Default notification processing (e.g., logging, progress)
          process_notification(server, method, params)
          # Invoke user-defined listeners
          @notification_listeners.each { |cb| cb.call(server, method, params) }
        end
      end

      # Drop the caches a notification invalidates.
      #
      # Registered on the transport's `on_cache_invalidation` hook, which runs
      # before the notification is delivered to a subscription's listeners — so a
      # listener that reacts to a `list_changed` notification by calling
      # `list_tools` (or the prompt/resource equivalents) re-fetches instead of
      # reading the entry the notification just invalidated. It used to ride on
      # `on_notification`, which round 10 moved to the end of the routing order
      # for good reason: that callback is host code and may block the very reader
      # the delivery came from. Only the cache drops moved forward; everything
      # else {#process_notification} does still runs behind the delivery.
      # @param server [MCPClient::ServerBase] the server that emitted it
      # @param method [String] JSON-RPC notification method
      # @return [void]
      def invalidate_caches_for_notification(server, method)
        server_id = notification_server_id(server)
        case method
        when 'notifications/tools/list_changed'
          logger.warn("[#{server_id}] Tool list has changed, clearing tool cache")
          clear_tool_cache
        when 'notifications/prompts/list_changed'
          logger.warn("[#{server_id}] Prompt list has changed, clearing prompt cache")
          @cache_mutex.synchronize do
            @cache_version += 1
            @prompt_cache.clear
            @cache_params.delete(:prompts)
            @cache_filled.delete(:prompts)
          end
        when 'notifications/resources/list_changed'
          logger.warn("[#{server_id}] Resource list has changed, clearing resource cache")
          @cache_mutex.synchronize do
            @cache_version += 1
            @resource_cache.clear
            @cache_params.delete(:resources)
            @cache_filled.delete(:resources)
          end
        end
      end

      # @param server [MCPClient::ServerBase] the server that emitted a notification
      # @return [String] the identity used to prefix its log lines
      def notification_server_id(server)
        server.name ? "#{server.class}[#{server.name}]" : server.class.to_s
      end

      # Process incoming JSON-RPC notifications with default handlers
      # @param server [MCPClient::ServerBase] the server that emitted the notification
      # @param method [String] JSON-RPC notification method
      # @param params [Hash] parameters for the notification
      # @return [void]
      def process_notification(server, method, params)
        server_id = notification_server_id(server)
        case method
        when 'notifications/tools/list_changed', 'notifications/prompts/list_changed',
             'notifications/resources/list_changed'
          # Already handled, ahead of the delivery to any subscription listener
          # (see {#invalidate_caches_for_notification}).
          nil
        when 'notifications/resources/updated'
          logger.warn("[#{server_id}] Resource #{params['uri']} updated")
        when 'notifications/message'
          # MCP 2025-06-18: Handle logging messages from server
          handle_log_message(server_id, params)
        when 'notifications/tasks/status', 'notifications/tasks'
          # (both handled below; the legacy method carries the flat 2025 shape)
          # MCP 2025-11-25: task status update (params are a flat Task);
          # MCP 2026-07-28 tasks extension: notifications/tasks carries a
          # DetailedTask (only ever on a subscriptions/listen stream).
          handle_task_status_notification(server_id, params, method)
        when 'notifications/subscriptions/acknowledged'
          # MCP 2026-07-28: the transport already recorded the acknowledged
          # filter on the Subscription; log for observability.
          sub_id = params&.dig('_meta', 'io.modelcontextprotocol/subscriptionId')
          logger.debug("[#{server_id}] Subscription #{sanitize_peer_log_text(sub_id.to_s)} acknowledged")
        when 'notifications/cancelled'
          # MCP 2025-11-25 cancellation utility: the server cancelled one of its
          # own in-flight requests (sampling/elicitation). Server-request
          # dispatch is synchronous per transport, so by the time this arrives
          # the handler has usually completed; receivers MAY ignore
          # cancellations they cannot honor — log for observability. On MCP
          # 2026-07-28 it only ever tears down a subscriptions/listen stream,
          # which the transport handled before this point.
          request_id = sanitize_peer_log_text(params&.dig('requestId').to_s)
          reason = sanitize_peer_log_text((params&.dig('reason') || 'no reason given').to_s)
          logger.debug("[#{server_id}] Server cancelled request #{request_id}: #{reason}")
        when 'notifications/progress'
          handle_progress_notification(server_id, params)
        else
          # Log unknown notification types for debugging purposes
          logger.debug("[#{server_id}] Received unknown notification: #{method} - #{params}")
        end
      end
    end
  end
end
