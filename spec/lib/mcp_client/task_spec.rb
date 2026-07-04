# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Task do
  describe '#initialize' do
    it 'creates a task with the given fields' do
      task = described_class.new(
        task_id: 't1', status: 'working', status_message: 'in progress',
        created_at: '2025-11-25T10:30:00Z', last_updated_at: '2025-11-25T10:40:00Z',
        ttl: 30_000, poll_interval: 5000
      )
      expect(task.task_id).to eq('t1')
      expect(task.status).to eq('working')
      expect(task.status_message).to eq('in progress')
      expect(task.created_at).to eq('2025-11-25T10:30:00Z')
      expect(task.last_updated_at).to eq('2025-11-25T10:40:00Z')
      expect(task.ttl).to eq(30_000)
      expect(task.poll_interval).to eq(5000)
    end

    it 'defaults status to working' do
      expect(described_class.new(task_id: 't1').status).to eq('working')
    end

    %w[working input_required completed failed cancelled].each do |status|
      it "accepts the valid status #{status}" do
        expect { described_class.new(task_id: 't1', status: status) }.not_to raise_error
      end
    end

    %w[pending running unknown].each do |status|
      it "rejects the invalid status #{status}" do
        expect { described_class.new(task_id: 't1', status: status) }
          .to raise_error(ArgumentError, /Invalid task status/)
      end
    end
  end

  describe '.from_json' do
    it 'parses a flat GetTaskResult shape' do
      task = described_class.from_json(
        {
          'taskId' => 't1', 'status' => 'working',
          'createdAt' => '2025-11-25T10:30:00Z', 'lastUpdatedAt' => '2025-11-25T10:40:00Z',
          'ttl' => 30_000, 'pollInterval' => 5000, 'statusMessage' => 'running'
        }
      )
      expect(task.task_id).to eq('t1')
      expect(task.status).to eq('working')
      expect(task.created_at).to eq('2025-11-25T10:30:00Z')
      expect(task.last_updated_at).to eq('2025-11-25T10:40:00Z')
      expect(task.ttl).to eq(30_000)
      expect(task.poll_interval).to eq(5000)
      expect(task.status_message).to eq('running')
    end

    it 'preserves a null ttl (key present, value null)' do
      task = described_class.from_json({ 'taskId' => 't1', 'status' => 'working', 'ttl' => nil })
      expect(task.ttl).to be_nil
    end
  end

  describe '.from_create_result' do
    it 'unwraps the task under the "task" key of a CreateTaskResult' do
      task = described_class.from_create_result({ 'task' => { 'taskId' => 'x', 'status' => 'working',
                                                              'ttl' => 60_000 } })
      expect(task.task_id).to eq('x')
      expect(task.status).to eq('working')
      expect(task.ttl).to eq(60_000)
    end

    it 'tolerates a flat result without a task wrapper' do
      task = described_class.from_create_result({ 'taskId' => 'x', 'status' => 'working' })
      expect(task.task_id).to eq('x')
    end
  end

  describe 'status predicates' do
    def build(status)
      described_class.new(task_id: 't', status: status)
    end

    it '#terminal? is true only for completed/failed/cancelled' do
      expect(build('completed').terminal?).to be true
      expect(build('failed').terminal?).to be true
      expect(build('cancelled').terminal?).to be true
      expect(build('working').terminal?).to be false
      expect(build('input_required').terminal?).to be false
    end

    it '#active? is the inverse of terminal?' do
      expect(build('working').active?).to be true
      expect(build('input_required').active?).to be true
      expect(build('completed').active?).to be false
    end

    it '#input_required? and #working? reflect the status' do
      expect(build('input_required').input_required?).to be true
      expect(build('working').working?).to be true
      expect(build('working').input_required?).to be false
    end
  end

  describe '#to_h' do
    it 'emits spec-shaped keys' do
      task = described_class.new(task_id: 't1', status: 'working', ttl: 30_000, poll_interval: 5000)
      expect(task.to_h).to eq('taskId' => 't1', 'status' => 'working', 'ttl' => 30_000, 'pollInterval' => 5000)
    end

    it 'always includes ttl (a required Task field, value may be null)' do
      task = described_class.new(task_id: 't1', status: 'working')
      expect(task.to_h).to eq('taskId' => 't1', 'status' => 'working', 'ttl' => nil)
    end
  end

  describe 'equality and representation' do
    it 'considers tasks with the same id and status equal' do
      a = described_class.new(task_id: 't1', status: 'working')
      b = described_class.new(task_id: 't1', status: 'working')
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it 'considers tasks with a different status not equal' do
      a = described_class.new(task_id: 't1', status: 'working')
      b = described_class.new(task_id: 't1', status: 'completed')
      expect(a).not_to eq(b)
    end

    it '#to_s and #inspect show the id and status' do
      task = described_class.new(task_id: 't1', status: 'working', status_message: 'busy')
      expect(task.to_s).to include('t1', 'working', 'busy')
      expect(task.inspect).to include('t1', 'working')
    end
  end

  describe 'constants' do
    it 'exposes the spec statuses' do
      expect(described_class::VALID_STATUSES).to eq(%w[working input_required completed failed cancelled])
      expect(described_class::VALID_STATUSES).to be_frozen
      expect(described_class::TERMINAL_STATUSES).to eq(%w[completed failed cancelled])
    end
  end
end
