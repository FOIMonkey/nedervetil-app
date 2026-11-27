require 'spec_helper'

RSpec.describe Disclosures::PiiCheck do
  def configure(mode, endpoint = 'http://127.0.0.1:5002/v1/check')
    allow(AlaveteliConfiguration).to receive(:disclosures_pii_check).
      and_return(mode)
    allow(AlaveteliConfiguration).to receive(:disclosures_pii_check_endpoint).
      and_return(endpoint)
  end

  def json(body, status: 200)
    { status: status, body: body.to_json,
      headers: { 'Content-Type' => 'application/json' } }
  end

  it 'is off unless configured, and then never answers clear' do
    expect(described_class).not_to be_enabled
    expect(described_class.call(['Jane'])).to eq(:unavailable)
  end

  it 'asks an ai service by the badger/v1 contract, with the token' do
    configure('ai')
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('DISCLOSURES_PII_CHECK_AUTH_TOKEN').
      and_return('secret-token')
    request = stub_request(:post, 'http://127.0.0.1:5002/v1/check').
              with(headers: { 'Authorization' => 'Bearer secret-token' },
                   body: hash_including('contract_version' => 'badger/v1',
                                        'text' => "Ask Anjali Raval\nTotals")).
              to_return(json({ findings: [{ type: 'PERSON', score: 0.9 }] }))
    expect(described_class.call(['Ask Anjali Raval', 'Totals'])).
      to eq(:personal)
    expect(request).to have_been_requested
  end

  it 'counts only the configured kinds, above the score' do
    configure('ai')
    stub_request(:post, 'http://127.0.0.1:5002/v1/check').
      to_return(json({ findings: [{ type: 'UK_NINO', score: 0.99 },
                                  { type: 'PERSON', score: 0.3 }] }))
    expect(described_class.call(['x'])).to eq(:clear)
  end

  it 'refuses an endpoint that is neither HTTPS nor on this machine' do
    configure('presidio', 'http://pii.example.org')
    expect(described_class.call(['Jane'])).to eq(:unavailable)
  end

  it 'won’t send more than its limit, and says so' do
    configure('ai')
    line = "#{'x' * 1000}\n"
    text = line * ((described_class::MAX_BYTES * described_class::MAX_CALLS /
                    line.bytesize) + 10)
    expect(described_class.call([text])).to eq(:unavailable)
  end

  it 'checks the whole of a line longer than one request' do
    configure('ai')
    seen = []
    stub_request(:post, 'http://127.0.0.1:5002/v1/check').
      to_return do |request|
        text = JSON.parse(request.body)['text']
        seen << text
        found = if text.include?('Anjali Raval')
                  [{ type: 'PERSON', score: 0.9 }]
                else
                  []
                end
        json({ findings: found })
      end
    line = "#{'x' * 205_000} Anjali Raval"
    expect(described_class.call([line])).to eq(:personal)
    expect(seen.join).to include('Anjali Raval')
    expect(seen.map(&:bytesize).max).to be <= described_class::MAX_BYTES

    # A name across a cut is in the overlap.
    cut = described_class::MAX_BYTES / 4
    pieces = described_class.pieces(
      "#{'y' * (cut - 6)}Anjali Raval#{'z' * cut}"
    )
    expect(pieces).to include(match(/Anjali Raval/))
  end

  it 'splits at 100 KB so a hit stops early, while keeping the 1 MB ceiling' do
    configure('ai')
    seen = []
    stub_request(:post, 'http://127.0.0.1:5002/v1/check').
      to_return do |request|
        text = JSON.parse(request.body)['text']
        seen << text
        found = if text.include?('Anjali Raval')
                  [{ type: 'PERSON', score: 0.9 }]
                else
                  []
                end
        json({ findings: found })
      end

    early = ['Anjali Raval'] + (['a' * 1000] * 150)
    expect(described_class.call(early)).to eq(:personal)
    expect(seen.size).to eq(1)
    expect(seen.first.bytesize).to be <= 100_000

    seen.clear
    late = (['a' * 1000] * 950) + ['Anjali Raval']
    expect(described_class.call(late)).to eq(:personal)
    expect(seen.size).to eq(10)
    expect(seen.map(&:bytesize).max).to be <= 100_000
  end

  it 'reads a Presidio analyzer’s answer' do
    configure('presidio', 'https://presidio.example.org/')
    stub_request(:post, 'https://presidio.example.org/analyze').
      with(body: hash_including('language' => 'en',
                                'entities' => %w[PERSON EMAIL_ADDRESS])).
      to_return(json([{ entity_type: 'EMAIL_ADDRESS', score: 1.0 }]))
    expect(described_class.call(['a@b.org'])).to eq(:personal)
  end

  it 'aborts streaming responses that exceed MAX_RESPONSE before buffering' do
    configure('ai')
    stub_const("#{described_class}::MAX_RESPONSE", 64)

    response = instance_double(Net::HTTPOK, code: '200')
    allow(response).to receive(:[]).with('Content-Length').and_return(nil)
    read_trailing_chunk = false
    allow(response).to receive(:read_body) do |&block|
      block.call('x' * 40)
      block.call('y' * 40)
      read_trailing_chunk = true
      block.call('z' * 10_000)
    end

    conn = instance_double(Net::HTTP)
    allow(conn).to receive(:request).and_yield(response)
    http = instance_double(Net::HTTP,
                           'use_ssl=': nil, 'verify_mode=': nil,
                           'open_timeout=': nil, 'read_timeout=': nil,
                           'write_timeout=': nil)
    allow(http).to receive(:start).and_yield(conn)
    allow(Net::HTTP).to receive(:new).and_return(http)

    expect(described_class.call(['Jane'])).to eq(:unavailable)
    expect(read_trailing_chunk).to be(false)
  end

  it 'rejects responses declaring an oversized Content-Length before reading' do
    configure('ai')
    stub_request(:post, 'http://127.0.0.1:5002/v1/check').
      to_return(status: 200,
                body: '{"findings":[]}',
                headers: {
                  'Content-Type' => 'application/json',
                  'Content-Length' => (described_class::MAX_RESPONSE + 1).to_s
                })
    expect(described_class.call(['Jane'])).to eq(:unavailable)
  end
end
