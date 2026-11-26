require 'spec_helper'

RSpec.describe IncomingAttention::Transport do
  subject(:transport) { described_class.new }

  let(:endpoint) { 'https://worker.example.invalid/v1/classify' }
  let(:token) { 'synthetic-token-' * 3 }
  let(:headers) { { 'Content-Type' => 'application/json' } }
  let(:error) { IncomingAttention::Client::Error }

  before do
    allow(IncomingAttention::Config).to receive(:endpoint).and_return(endpoint)
    allow(IncomingAttention::Config).to receive(:token).and_return(token)
  end

  %w[classify outcome].each do |route|
    it "posts #{route} to the configured host with the same authentication" do
      request = stub_request(:post, "https://worker.example.invalid/v1/#{route}").
        with(body: '{"message_id":1}',
             headers: { 'Authorization' => "Bearer #{token}",
                        'Content-Type' => 'application/json',
                        'Accept' => 'application/json' }).
        to_return(status: 200, body: '{}', headers: headers)

      expect(transport.post('{"message_id":1}', path: "/v1/#{route}")).
        to eq([200, '{}'])
      expect(request).to have_been_requested.once
    end
  end

  { 401 => 'worker_authentication', 403 => 'worker_authentication',
    302 => 'worker_redirect' }.each do |status, code|
    it "rejects HTTP #{status}" do
      stub_request(:post, endpoint).to_return(status: status, headers: headers)

      expect { transport.post('{}') }.to raise_error(error, code)
    end
  end

  describe 'through an anonymiser' do
    def anonymise_via(url)
      allow(IncomingAttention::Config).to receive(:anonymiser_endpoint).
        and_return(url)
    end

    it 'posts straight to the worker when none is set, without its token' do
      allow(IncomingAttention::Config).to receive(:anonymiser_token).
        and_return('anonymiser-token')
      expect(IncomingAttention::Config).not_to be_anonymising
      request = stub_request(:post, endpoint).
                to_return(status: 200, body: '{}', headers: headers)
      transport.post('{}')
      expect(request).to have_been_requested.once
      expect(
        a_request(:post, endpoint).
          with { |sent| sent.headers.key?('X-Anonymiser-Token') }
      ).not_to have_been_made
    end

    %w[classify outcome].each do |route|
      it "sends #{route} to it with the same body and worker token, and returns the worker's answer" do
        anonymise_via('http://127.0.0.1:5002')
        allow(IncomingAttention::Config).to receive(:anonymiser_token).
          and_return('anonymiser-token')
        request = stub_request(:post, "http://127.0.0.1:5002/v1/#{route}").
                  with(body: '{"message_id":1}',
                       headers: { 'Authorization' => "Bearer #{token}",
                                  'X-Anonymiser-Token' => 'anonymiser-token' }).
                  to_return(status: 200, body: '{"kind":"x"}', headers: headers)
        worker = stub_request(:post, %r{worker\.example\.invalid})

        expect(transport.post('{"message_id":1}', path: "/v1/#{route}")).
          to eq([200, '{"kind":"x"}'])
        expect(request).to have_been_requested.once
        expect(worker).not_to have_been_requested
      end
    end

    it 'keeps the path the anonymiser is served under' do
      anonymise_via('https://anonymiser.example.invalid/relay/')
      request = stub_request(:post,
                             'https://anonymiser.example.invalid/relay/v1/classify').
                to_return(status: 200, body: '{}', headers: headers)
      transport.post('{}')
      expect(request).to have_been_requested.once
    end

    it 'refuses one that is neither HTTPS nor on this machine' do
      anonymise_via('http://anonymiser.example.invalid')
      expect { transport.post('{}') }.
        to raise_error(error, 'anonymiser_unconfigured')
    end

    it 'still needs the worker to be configured' do
      anonymise_via('http://127.0.0.1:5002')
      allow(IncomingAttention::Config).to receive(:token).and_return('')
      expect { transport.post('{}') }.
        to raise_error(error, 'worker_unconfigured')
    end
  end

  it 'rejects non-JSON responses' do
    stub_request(:post, endpoint).to_return(body: '<html>Error</html>')

    expect { transport.post('{}') }.
      to raise_error(error, 'worker_content_type')
  end

  it 'bounds the response before parsing it' do
    bytes = 'x' * (IncomingAttention::Config::MAX_RESPONSE_BYTES + 1)
    stub_request(:post, endpoint).to_return(body: bytes, headers: headers)

    expect { transport.post('{}') }.to raise_error(error, 'response_limit')
  end

  it 'reports connection errors without disclosing their contents' do
    stub_request(:post, endpoint).to_raise(StandardError.new('private detail'))
    allow(Rails.logger).to receive(:warn).and_call_original

    expect { transport.post('{}') }.
      to raise_error(error, 'transport_failure') { |failure|
        expect(failure.status).to eq('unavailable')
        expect(failure.retryable).to be true
      }
    expect(Rails.logger).to have_received(:warn).
      with('incoming_attention_transport_failed StandardError')
  end
end
