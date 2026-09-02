# frozen_string_literal: true

module MCPClient
  class ServerStdio
    # The record of one server child process: when the open subscriptions were
    # handed to it, and when its handles were torn down. One record per
    # process, written only by that process's own lifecycle, so nothing
    # another thread does to another process can change what this one says.
    #
    # It exists for the crash-loop bound. That bound used to live in flags and
    # a timestamp on the transport, which two restarts (or a restart and a host
    # request that re-established the process first) raced over: whichever
    # finished last decided what the *other* process's uptime had been, and a
    # server that exited on sight could be respawned for ever. The question a
    # restart actually has to answer is about one particular process — "did the
    # last process we gave these subscriptions to die straight after we gave
    # them to it?" — and both facts it needs are recorded here, on that
    # process, at the two moments they happen.
    class ChildSession
      # @return [Float, nil] monotonic time the open subscriptions were re-sent
      #   to this process, nil if it was never asked to carry any
      attr_reader :carried_at
      # @return [Float, nil] monotonic time this process's handles were torn
      #   down, nil while it is still the live session
      attr_reader :ended_at

      def initialize
        @carried_at = nil
        @ended_at = nil
      end

      # @return [Float] monotonic seconds
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # This process has been handed the subscriptions a previous process left
      # open. Stamped before they go out, not after: the process can exit while
      # they are still being written, and an exit under the re-send is the
      # clearest crash loop there is.
      # @return [void]
      def carrying_subscriptions
        @carried_at = ChildSession.now
      end

      # This process is gone (its stdio handles have been torn down). First
      # stamp wins: a host `cleanup` racing the reader's own teardown must not
      # move the moment the process ended.
      # @return [void]
      def ended
        return if @ended_at

        @ended_at = ChildSession.now
      end

      # Whether this process died too soon after being given the subscriptions
      # to be given them again — the crash loop the restart bound exists to
      # stop. A process that was never given any is not part of that loop, and
      # one that is still alive has not ended anything.
      #
      # The interval is measured from the moment it received them, so a server
      # that is slow to start is credited with none of its own handshake, and a
      # process that was already gone when they were sent to it (its exit
      # stamped before the re-send) counts as having survived no time at all.
      # @param min_uptime [Numeric] seconds it had to last (see
      #   {MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL})
      # @return [Boolean]
      def died_carrying_subscriptions?(min_uptime)
        return false unless @carried_at && @ended_at

        (@ended_at - @carried_at) < min_uptime
      end
    end
  end
end
