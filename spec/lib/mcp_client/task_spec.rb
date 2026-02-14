# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Task do
  describe '#initialize' do
    it 'creates a task with required attributes' do
      task = described_class.new(id: 'task-123')
      expect(task.id).to eq('task-123')
      expect(task.state).to eq('pending')
    end

    it 'creates a task with all attributes' do
      task = described_class.new(
        id: 'task-123',
        state: 'running',
        progress_token: 'pt-456',
        progress: 50,
        total: 100,
        message: 'Processing...',
        result: { 'data' => 'value' }
      )
      expect(task.id).to eq('task-123')
      expect(task.state).to eq('running')
      expect(task.progress_token).to eq('pt-456')
      expect(task.progress).to eq(50)
      expect(task.total).to eq(100)
      expect(task.message).to eq('Processing...')
      expect(task.result).to eq({ 'data' => 'value' })
    end

    it 'raises ArgumentError for invalid state' do
      expect do
        described_class.new(id: 'task-123', state: 'invalid')
      end.to raise_error(ArgumentError, /Invalid task state/)
    end

    it 'accepts all valid states' do
      %w[pending running completed failed cancelled].each do |state|
        task = described_class.new(id: 'task-123', state: state)
        expect(task.state).to eq(state)
      end
    end

    it 'stores server reference' do
      server = instance_double(MCPClient::ServerBase)
      task = described_class.new(id: 'task-123', server: server)
      expect(task.server).to eq(server)
    end
  end

  describe '.from_json' do
    it 'parses JSON with string keys' do
      json = {
        'id' => 'task-abc',
        'state' => 'running',
        'progressToken' => 'pt-xyz',
        'progress' => 25,
        'total' => 100,
        'message' => 'In progress',
        'result' => { 'output' => 'data' }
      }
      task = described_class.from_json(json)

      expect(task.id).to eq('task-abc')
      expect(task.state).to eq('running')
      expect(task.progress_token).to eq('pt-xyz')
      expect(task.progress).to eq(25)
      expect(task.total).to eq(100)
      expect(task.message).to eq('In progress')
      expect(task.result).to eq({ 'output' => 'data' })
    end

    it 'parses JSON with symbol keys' do
      json = {
        id: 'task-abc',
        state: 'completed',
        progressToken: 'pt-xyz',
        progress: 100,
        total: 100,
        message: 'Done',
        result: { 'output' => 'data' }
      }
      task = described_class.from_json(json)

      expect(task.id).to eq('task-abc')
      expect(task.state).to eq('completed')
      expect(task.progress_token).to eq('pt-xyz')
    end

    it 'handles missing optional fields' do
      json = { 'id' => 'task-abc' }
      task = described_class.from_json(json)

      expect(task.id).to eq('task-abc')
      expect(task.state).to eq('pending')
      expect(task.progress_token).to be_nil
      expect(task.progress).to be_nil
      expect(task.total).to be_nil
      expect(task.message).to be_nil
      expect(task.result).to be_nil
    end

    it 'accepts a server parameter' do
      server = instance_double(MCPClient::ServerBase)
      json = { 'id' => 'task-abc', 'state' => 'pending' }
      task = described_class.from_json(json, server: server)

      expect(task.server).to eq(server)
    end

    it 'handles snake_case progress_token key' do
      json = { id: 'task-abc', progress_token: 'pt-xyz' }
      task = described_class.from_json(json)

      expect(task.progress_token).to eq('pt-xyz')
    end
  end

  describe '#to_h' do
    it 'returns hash with required fields only' do
      task = described_class.new(id: 'task-123', state: 'pending')
      expect(task.to_h).to eq({ 'id' => 'task-123', 'state' => 'pending' })
    end

    it 'includes optional fields when present' do
      task = described_class.new(
        id: 'task-123',
        state: 'running',
        progress_token: 'pt-456',
        progress: 50,
        total: 100,
        message: 'Working...',
        result: { 'data' => 'value' }
      )
      hash = task.to_h

      expect(hash['id']).to eq('task-123')
      expect(hash['state']).to eq('running')
      expect(hash['progressToken']).to eq('pt-456')
      expect(hash['progress']).to eq(50)
      expect(hash['total']).to eq(100)
      expect(hash['message']).to eq('Working...')
      expect(hash['result']).to eq({ 'data' => 'value' })
    end

    it 'excludes nil optional fields' do
      task = described_class.new(id: 'task-123')
      hash = task.to_h

      expect(hash).not_to have_key('progressToken')
      expect(hash).not_to have_key('progress')
      expect(hash).not_to have_key('total')
      expect(hash).not_to have_key('message')
      expect(hash).not_to have_key('result')
    end
  end

  describe '#to_json' do
    it 'serializes to JSON string' do
      task = described_class.new(id: 'task-123', state: 'running', message: 'Working')
      json = task.to_json
      parsed = JSON.parse(json)

      expect(parsed['id']).to eq('task-123')
      expect(parsed['state']).to eq('running')
      expect(parsed['message']).to eq('Working')
    end
  end

  describe '#terminal?' do
    it 'returns true for completed state' do
      expect(described_class.new(id: 't', state: 'completed').terminal?).to be true
    end

    it 'returns true for failed state' do
      expect(described_class.new(id: 't', state: 'failed').terminal?).to be true
    end

    it 'returns true for cancelled state' do
      expect(described_class.new(id: 't', state: 'cancelled').terminal?).to be true
    end

    it 'returns false for pending state' do
      expect(described_class.new(id: 't', state: 'pending').terminal?).to be false
    end

    it 'returns false for running state' do
      expect(described_class.new(id: 't', state: 'running').terminal?).to be false
    end
  end

  describe '#active?' do
    it 'returns true for pending state' do
      expect(described_class.new(id: 't', state: 'pending').active?).to be true
    end

    it 'returns true for running state' do
      expect(described_class.new(id: 't', state: 'running').active?).to be true
    end

    it 'returns false for completed state' do
      expect(described_class.new(id: 't', state: 'completed').active?).to be false
    end

    it 'returns false for failed state' do
      expect(described_class.new(id: 't', state: 'failed').active?).to be false
    end

    it 'returns false for cancelled state' do
      expect(described_class.new(id: 't', state: 'cancelled').active?).to be false
    end
  end

  describe '#progress_percentage' do
    it 'calculates percentage when progress and total are set' do
      task = described_class.new(id: 't', state: 'running', progress: 25, total: 200)
      expect(task.progress_percentage).to eq(12.5)
    end

    it 'returns 100.0 when progress equals total' do
      task = described_class.new(id: 't', state: 'completed', progress: 100, total: 100)
      expect(task.progress_percentage).to eq(100.0)
    end

    it 'returns nil when progress is nil' do
      task = described_class.new(id: 't', state: 'running', total: 100)
      expect(task.progress_percentage).to be_nil
    end

    it 'returns nil when total is nil' do
      task = described_class.new(id: 't', state: 'running', progress: 50)
      expect(task.progress_percentage).to be_nil
    end

    it 'returns nil when total is zero' do
      task = described_class.new(id: 't', state: 'running', progress: 0, total: 0)
      expect(task.progress_percentage).to be_nil
    end
  end

  describe 'equality' do
    it 'considers tasks with same id and state as equal' do
      task1 = described_class.new(id: 'task-123', state: 'running')
      task2 = described_class.new(id: 'task-123', state: 'running')

      expect(task1).to eq(task2)
      expect(task1.eql?(task2)).to be true
      expect(task1.hash).to eq(task2.hash)
    end

    it 'considers tasks with different id as not equal' do
      task1 = described_class.new(id: 'task-123', state: 'running')
      task2 = described_class.new(id: 'task-456', state: 'running')

      expect(task1).not_to eq(task2)
    end

    it 'considers tasks with different state as not equal' do
      task1 = described_class.new(id: 'task-123', state: 'running')
      task2 = described_class.new(id: 'task-123', state: 'completed')

      expect(task1).not_to eq(task2)
    end
  end

  describe '#to_s' do
    it 'returns basic string for simple task' do
      task = described_class.new(id: 'task-123', state: 'pending')
      expect(task.to_s).to eq('Task[task-123]: pending')
    end

    it 'includes progress when available' do
      task = described_class.new(id: 'task-123', state: 'running', progress: 50, total: 100)
      expect(task.to_s).to eq('Task[task-123]: running (50/100)')
    end

    it 'includes message when available' do
      task = described_class.new(id: 'task-123', state: 'running', message: 'Processing files')
      expect(task.to_s).to eq('Task[task-123]: running - Processing files')
    end

    it 'includes both progress and message' do
      task = described_class.new(id: 'task-123', state: 'running', progress: 3, total: 10, message: 'Step 3')
      expect(task.to_s).to eq('Task[task-123]: running (3/10) - Step 3')
    end
  end

  describe '#inspect' do
    it 'returns a readable representation' do
      task = described_class.new(id: 'task-123', state: 'running')
      expect(task.inspect).to eq('#<MCPClient::Task id="task-123" state="running">')
    end
  end

  describe 'VALID_STATES' do
    it 'contains all expected states' do
      expect(described_class::VALID_STATES).to eq(%w[pending running completed failed cancelled])
    end

    it 'is frozen' do
      expect(described_class::VALID_STATES).to be_frozen
    end
  end
end
