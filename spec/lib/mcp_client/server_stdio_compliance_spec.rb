# frozen_string_literal: true

require 'spec_helper'

# Compliance specs for the MCP 2025-11-25 stdio transport.
#
# - basic/transports.mdx: "JSON-RPC messages MUST be UTF-8 encoded."
# - basic/lifecycle.mdx (Shutdown / stdio): the client SHOULD initiate shutdown
#   by (1) closing the input stream to the child process, (2) waiting for the
#   server to exit, or sending SIGTERM if it does not exit within a reasonable
#   time, and (3) sending SIGKILL if it still does not exit after SIGTERM.
RSpec.describe MCPClient::ServerStdio do
  describe 'UTF-8 enforcement on subprocess pipes' do
    # Simulate a non-UTF-8 locale (e.g. LANG=C in containers/CI): pipes created
    # while Encoding.default_external is US-ASCII inherit that encoding unless
    # the transport pins UTF-8 explicitly.
    around do |example|
      original_encoding = Encoding.default_external
      original_verbose = $VERBOSE
      $VERBOSE = nil
      Encoding.default_external = Encoding::US_ASCII
      example.run
    ensure
      Encoding.default_external = original_encoding
      $VERBOSE = original_verbose
    end

    it 'pins the subprocess pipes to UTF-8 regardless of the process locale' do
      server = described_class.new(command: ['ruby', '-e', '$stdin.read'])
      server.connect
      expect(server.instance_variable_get(:@stdout).external_encoding).to eq(Encoding::UTF_8)
      expect(server.instance_variable_get(:@stderr).external_encoding).to eq(Encoding::UTF_8)
      expect(server.instance_variable_get(:@stdin).external_encoding).to eq(Encoding::UTF_8)
    ensure
      server.cleanup
    end

    it 'delivers a valid UTF-8 response under a non-UTF-8 locale instead of killing the reader thread' do
      script = '$stdout.puts(%({"jsonrpc":"2.0","id":1,"result":{"text":"żółć"}})); $stdout.flush; $stdin.read'
      server = described_class.new(command: ['ruby', '-e', script], read_timeout: 3)
      server.connect
      server.instance_variable_set(:@awaiting, { 1 => true })
      server.start_reader

      response = server.send(:wait_response, 1)
      expect(response['result']).to eq({ 'text' => 'żółć' })
    ensure
      server.cleanup
    end
  end

  describe 'shutdown sequence' do
    context 'with a real subprocess' do
      it 'does not signal a well-behaved server that exits when stdin is closed' do
        server = described_class.new(command: ['ruby', '-e', '$stdin.read'])
        server.connect
        expect(Process).not_to receive(:kill)
        server.cleanup
      end

      it 'escalates to SIGKILL when the server ignores SIGTERM' do
        stub_const('MCPClient::ServerStdio::SHUTDOWN_GRACE_PERIOD', 0.2)
        script = 'Signal.trap("TERM") {}; $stdout.puts("ready"); $stdout.flush; $stdin.read; sleep 60'
        server = described_class.new(command: ['ruby', '-e', script])
        server.connect
        # Wait until the TERM handler is installed before shutting down
        expect(server.instance_variable_get(:@stdout).gets).to eq("ready\n")
        pid = server.instance_variable_get(:@wait_thread).pid

        server.cleanup
        expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      ensure
        begin
          Process.kill('KILL', pid) if pid
        rescue Errno::ESRCH
          # already gone — expected
        end
      end
    end

    context 'with a mocked subprocess' do
      let(:server) { described_class.new(command: 'echo test') }

      before do
        @stdin = double('stdin', close: nil, closed?: false)
        @stdout = double('stdout', close: nil, closed?: false)
        @stderr = double('stderr', close: nil, closed?: false)
        @wait_thread = double('wait_thread', pid: 12_345, alive?: true, join: nil)
        @reader_thread = double('reader_thread', kill: nil)
        @stderr_thread = double('stderr_thread', kill: nil)

        allow(Process).to receive(:kill)

        server.instance_variable_set(:@stdin, @stdin)
        server.instance_variable_set(:@stdout, @stdout)
        server.instance_variable_set(:@stderr, @stderr)
        server.instance_variable_set(:@wait_thread, @wait_thread)
        server.instance_variable_set(:@reader_thread, @reader_thread)
        server.instance_variable_set(:@stderr_thread, @stderr_thread)
      end

      it 'follows the close-stdin -> wait -> SIGTERM -> wait -> SIGKILL sequence' do
        events = []
        allow(@stdin).to receive(:close) { events << :close_stdin }
        allow(@wait_thread).to receive(:join) do |timeout|
          events << [:join, timeout]
          nil
        end
        allow(Process).to receive(:kill) { |sig, _pid| events << [:kill, sig] }

        server.cleanup

        grace = described_class::SHUTDOWN_GRACE_PERIOD
        expect(events).to eq(
          [
            :close_stdin,
            [:join, grace],
            [:kill, 'TERM'],
            [:join, grace],
            [:kill, 'KILL'],
            [:join, grace]
          ]
        )
      end

      it 'sends no signal when the process exits within the grace period after stdin closes' do
        allow(@wait_thread).to receive(:join).and_return(@wait_thread)
        expect(Process).not_to receive(:kill)
        server.cleanup
      end

      it 'continues cleanup when the process is already dead (Errno::ESRCH)' do
        allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
        expect(@reader_thread).to receive(:kill)
        expect(@stderr_thread).to receive(:kill)
        expect { server.cleanup }.not_to raise_error
      end
    end
  end

  describe '#handle_line robustness' do
    let(:server) { described_class.new(command: 'echo test') }

    it 'skips JSON-parseable lines that are not objects instead of raising' do
      expect { server.send(:handle_line, "[]\n") }.not_to raise_error
      expect { server.send(:handle_line, "123\n") }.not_to raise_error
      expect { server.send(:handle_line, "\"text\"\n") }.not_to raise_error
      expect { server.send(:handle_line, "null\n") }.not_to raise_error
    end

    it 'keeps handling subsequent valid messages after a non-object line' do
      server.instance_variable_set(:@awaiting, { 7 => true })
      server.send(:handle_line, "[]\n")
      server.send(:handle_line, { 'jsonrpc' => '2.0', 'id' => 7, 'result' => 'ok' }.to_json)
      expect(server.instance_variable_get(:@pending)[7]).to include('result' => 'ok')
    end

    it 'does not raise on a line that cannot be decoded (EncodingError)' do
      line = (+%({"jsonrpc":"2.0","id":1,"result":"ż"})).force_encoding(Encoding::US_ASCII)
      expect { server.send(:handle_line, line) }.not_to raise_error
    end
  end
end
