# frozen_string_literal: true

require 'spec_helper'
require 'zlib'
require 'stringio'

RSpec.describe MCPClient::HttpTransportBase::SseEventScanner do
  def events_from(*chunks)
    scanner = described_class.new
    events = []
    chunks.each { |chunk| scanner.feed(chunk) { |event| events << event } }
    [events, scanner.count]
  end

  it 'yields each event at its terminating blank line' do
    events, count = events_from("data: a\n\ndata: b\n\n")

    expect(events).to eq(['data: a', 'data: b'])
    expect(count).to eq(2)
  end

  it 'holds an event whose terminator has not arrived' do
    events, = events_from("data: a\n\ndata: b\n")

    expect(events).to eq(['data: a'])
  end

  # A trailing CR terminates a line whatever follows it; only whether the
  # next byte is the LF of a CRLF is unknown. Holding the CR back would
  # leave an event that is already complete undispatched until the server,
  # which may be waiting for the answer, sends something more.
  it 'dispatches an event terminated by bare CR without waiting for another chunk' do
    events, = events_from("data: a\r\r")

    expect(events).to eq(['data: a'])
  end

  it 'counts a CRLF terminator split across chunks once' do
    events, count = events_from("data: a\r\n\r", "\n", "data: b\r\n\r\n")

    expect(events).to eq(['data: a', 'data: b'])
    expect(count).to eq(2)
  end

  it 'still scans a stream whose first chunk is only a blank line' do
    events, = events_from("\n", "data: a\n\n")

    expect(events).to eq(['data: a'])
  end

  it 'yields comment-only events, which the completed body splits into too' do
    events, count = events_from(": keep-alive\n\ndata: a\n\n")

    expect(events).to eq([': keep-alive', 'data: a'])
    expect(count).to eq(2)
  end

  it 'never scans a body that does not start like an event stream' do
    events, count = events_from('{"jsonrpc":"2.0","id":1,"result":{}}', "\n\n")

    expect(events).to be_empty
    expect(count).to eq(0)
  end

  # SSE "Parsing an event stream": a field whose name the client does not
  # know is ignored, not a reason to stop reading the stream. A server that
  # opens its stream with one still has its ping answered while the stream
  # is open.
  it 'scans a stream whose first field is one it does not know' do
    events, = events_from("x-ignore: 1\ndata: a\n\n")

    expect(events).to eq(["x-ignore: 1\ndata: a"])
  end

  # The field name is what says "event stream", and it is not complete until
  # its colon or its line terminator arrives. Settling on the first few bytes
  # of a name split across chunks would decide "not an event stream" for a
  # stream that is one, and nothing on it would ever be delivered.
  it 'waits for the end of a field name split across chunks before deciding' do
    events, = events_from('x-igno', "re: 1\ndata: a\n\n")

    expect(events).to eq(["x-ignore: 1\ndata: a"])
  end

  # SSE "Parsing an event stream": a line with no colon is a field whose
  # value is the empty string, so a stream may legitimately open with one.
  it 'scans a stream whose first field has no colon at all' do
    events, = events_from("x-ignore\ndata: a\n\n")

    expect(events).to eq(["x-ignore\ndata: a"])
  end

  it 'settles on a JSON body as soon as its first byte arrives' do
    events, count = events_from('{', '"jsonrpc":"2.0","id":1,"result":{}}')

    expect(events).to be_empty
    expect(count).to eq(0)
  end

  it 'skips a leading byte-order mark' do
    events, = events_from("\xEF\xBB\xBF".b, "data: a\n\n")

    expect(events).to eq(['data: a'])
  end

  def gzip(text)
    StringIO.new.tap { |io| Zlib::GzipWriter.wrap(io) { |gz| gz.write(text) } }.string
  end

  # Streamable HTTP offers gzip on every request, so a live stream is usually
  # a compressed one: its events are inflated as the bytes arrive.
  it 'inflates a gzip body and yields its events as they arrive' do
    compressed = gzip("data: a\n\ndata: b\n\n")
    half = compressed.bytesize / 2
    events, count = events_from(compressed[0, half], compressed[half..])

    expect(events).to eq(['data: a', 'data: b'])
    expect(count).to eq(2)
  end

  it 'yields a compressed event before the gzip footer has arrived' do
    compressed = gzip("data: a\n\n")
    events, = events_from(compressed[0, compressed.bytesize - 8])

    expect(events).to eq(['data: a'])
  end

  it 'stops scanning a gzip body that is not an event stream' do
    events, count = events_from(gzip('{"jsonrpc":"2.0","id":1,"result":{}}'))

    expect(events).to be_empty
    expect(count).to eq(0)
  end

  # The peer controls the compression ratio. The bound is applied to the
  # inflated pieces as zlib produces them, so a body that expands far past
  # it is never allocated in full before the check.
  it 'stops scanning a gzip body once its expansion crosses the bound, before allocating it' do
    bomb = gzip("#{'a' * (8 * 1024 * 1024)}\n\ndata: late\n\n")
    inflated = 0
    allow_any_instance_of(Zlib::Inflate).to receive(:inflate).and_wrap_original do |original, bytes, &block|
      if block
        original.call(bytes) do |piece|
          inflated += piece.bytesize
          block.call(piece)
        end
      else
        original.call(bytes).tap { |text| inflated += text.bytesize }
      end
    end
    scanner = described_class.new(max_inflated_bytes: 1024)
    events = []
    scanner.feed(bomb) { |event| events << event }

    expect(events).to be_empty
    expect(scanner.count).to eq(0)
    expect(inflated).to be <= 1024 + (64 * 1024)
  end
end
