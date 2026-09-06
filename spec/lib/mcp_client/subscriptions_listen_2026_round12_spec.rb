# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# Review round 12 (codex): the restart lifecycle end to end, driven by the
# operating system rather than by scripted lifecycle methods — a real child
# process that acknowledges a listen, delivers on it and then exits on its
# own; the reader's EOF, the replacement's negotiation, the re-sent listen
# under a fresh id, and delivery on that id, all on one handle.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 12' do
  # A real MCP stdio server: a 2026-07-28 peer that acknowledges every listen,
  # sends one tagged tools/list_changed on it, and — in its first generation
  # only — then exits without a closing response.
  def stdio_server_source
    <<~RUBY
      require 'json'
      $stdout.sync = true

      state = ENV.fetch('MCP_SPEC_STATE')
      generation = (File.exist?(state) ? File.read(state).to_i : 0) + 1
      File.write(state, generation.to_s)
      sub_meta = 'io.modelcontextprotocol/subscriptionId'
      discover = {
        'resultType' => 'complete',
        'supportedVersions' => ['2026-07-28'],
        'capabilities' => { 'tools' => { 'listChanged' => true } }
      }

      $stdin.each_line do |line|
        begin
          message = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        case message['method']
        when 'server/discover'
          $stdout.puts(JSON.generate('jsonrpc' => '2.0', 'id' => message['id'], 'result' => discover))
        when 'subscriptions/listen'
          id = message['id']
          $stdout.puts(JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
                                     'params' => { '_meta' => { sub_meta => id },
                                                   'notifications' => message['params']['notifications'] }))
          $stdout.puts(JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                                     'params' => { '_meta' => { sub_meta => id }, 'generation' => generation,
                                                   'listenId' => id }))
          if generation == 1
            # An unexpected exit: no closing response, EOF on the pipe.
            sleep 0.1
            exit!(0)
          end
        end
      end
    RUBY
  end

  let(:workdir) { Dir.mktmpdir('mcp-round12') }
  let(:script) { File.join(workdir, 'server.rb') }
  let(:state_path) { File.join(workdir, 'generation') }
  let(:server) do
    MCPClient::ServerStdio.new(command: [RbConfig.ruby, script], read_timeout: 5, discover_timeout: 5,
                               env: { 'MCP_SPEC_STATE' => state_path })
  end

  before { File.write(script, stdio_server_source) }

  after do
    server.cleanup
  rescue StandardError
    nil
  ensure
    FileUtils.remove_entry(workdir)
  end

  def wait_until(timeout = 10)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    raise 'condition not met in time' unless yield
  end

  it 'survives the process exiting: the replacement is negotiated, the listen re-sent and delivery resumes' do
    # The listen establishes the process itself. An explicit `connect` first
    # would spawn a child that `ensure_initialized` then replaces with a
    # second one (the transport re-spawns on its first request, as it always
    # has), and the two children racing for the generation file is what made
    # this example flaky: whichever read it first decided who was generation 1.
    deliveries = Thread::Queue.new
    subscription = server.listen(notifications: { tools_list_changed: true }) do |method, params|
      deliveries << [method, params['generation'], params['listenId']]
    end
    first_id = subscription.id

    first = deliveries.pop(timeout: 10)
    expect(first).to eq(['notifications/tools/list_changed', 1, first_id])

    # The child exits after that delivery; its reader's EOF restarts it and
    # hands the open subscription to the replacement under a fresh id.
    second = deliveries.pop(timeout: 10)
    expect(second).not_to be_nil, 'no delivery from the replacement process'
    expect(second.first).to eq('notifications/tools/list_changed')
    expect(second[1]).to eq(2)
    wait_until { subscription.active? && subscription.id == second[2] }
    expect(subscription.id).not_to eq(first_id)
    expect(File.read(state_path).to_i).to eq(2)
    expect(subscription).not_to be_closed
    expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })

    subscription.close
    expect(subscription).to be_closed_by_client
  end
end
