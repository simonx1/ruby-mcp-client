# frozen_string_literal: true

module MCPClient
  # Whether the request a thread last resolved went through a multi
  # round-trip retry (MCP 2026-07-28 InputRequiredResult). A result that
  # depended on input responses MUST NOT be cached, and the marker is
  # thread-local because a transport serves concurrent requests: another
  # request completing meanwhile says nothing about this one.
  module RoundTripMarker
    private

    # @return [Boolean]
    def last_result_from_round_trip?
      Thread.current[round_trip_marker_key] == true
    end

    # @param flag [Boolean]
    # @return [void]
    def mark_round_trip_result(flag)
      Thread.current[round_trip_marker_key] = flag
    end

    # @return [Symbol] the thread-local key of this transport's round-trip marker
    def round_trip_marker_key
      :"mcp_client_round_trip_#{object_id}"
    end
  end
end
