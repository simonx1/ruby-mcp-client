# frozen_string_literal: true

require_relative '../task'
require_relative '../errors'

module MCPClient
  class Client
    # The shape checks of MCP 2026-07-28 task payloads (Task, DetailedTask
    # and the payload a status implies), shared by the task support.
    module TaskShape
      private

      # A modern tasks/get result is a DetailedTask: every field the Task
      # shape requires must be there (ttlMs may be null but must be
      # present), since a defaulted status or a missing TTL would drive the
      # wait on made-up state.
      # @param result [Object] the raw tasks/get result
      # @return [void]
      # @raise [MCPClient::Errors::InvalidResultError]
      def validate_detailed_task_shape!(result)
        problem = detailed_task_shape_problem(result)
        raise MCPClient::Errors::InvalidResultError, "Invalid tasks/get result: #{problem}" if problem
      end

      # @return [String, nil] what is wrong with a DetailedTask's shape
      def detailed_task_shape_problem(result)
        task_shape_problem(result) || task_status_payload_problem(result)
      end

      # The fields every Task carries (CreateTaskResult and DetailedTask
      # alike): a status, parseable timestamps and a ttlMs key.
      # @param result [Object]
      # @return [String, nil]
      def task_shape_problem(result)
        return 'not an object' unless result.is_a?(Hash)
        return 'taskId is not a string' unless result['taskId'].is_a?(String)
        return 'status is not a task status' unless MCPClient::Task::VALID_STATUSES.include?(result['status'])

        problem = task_timestamp_problem(result)
        return problem if problem
        return 'ttlMs is missing' unless result.key?('ttlMs')
        return 'ttlMs is not an integer or null' unless result['ttlMs'].nil? || result['ttlMs'].is_a?(Integer)

        nil
      end

      # The timestamps of a Task are ISO 8601; one that does not parse could
      # never bound a wait, so it is not a task at all.
      # @return [String, nil]
      def task_timestamp_problem(result)
        %w[createdAt lastUpdatedAt].each do |field|
          return "#{field} is not a string" unless result[field].is_a?(String)
          return "#{field} is not an ISO 8601 timestamp" unless iso8601?(result[field])
        end
        nil
      end

      # @return [Boolean]
      def iso8601?(text)
        Time.iso8601(text)
        true
      rescue ArgumentError
        false
      end

      # The payload a DetailedTask's status implies ("If status is completed,
      # result MUST be included; if failed, error; if input_required,
      # inputRequests").
      # @return [String, nil]
      def task_status_payload_problem(result)
        case result['status']
        when 'completed'
          unless MCPClient::Task.complete_result_object?(result['result'])
            'a completed task needs an object result whose resultType, if any, is "complete"'
          end
        when 'failed'
          unless MCPClient::Task.jsonrpc_error_object?(result['error'])
            'a failed task needs a JSON-RPC error object (integer code, string message)'
          end
        when 'input_required'
          'an input_required task needs an inputRequests object' unless result['inputRequests'].is_a?(Hash)
        end
      end
    end
  end
end
