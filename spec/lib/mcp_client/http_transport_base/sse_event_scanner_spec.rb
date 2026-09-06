# frozen_string_literal: true

require 'spec_helper'

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

  it 'never scans a gzip body' do
    events, = events_from("\x1F\x8B\x08\x00".b, "\n\n\n\n")

    expect(events).to be_empty
  end
end
