require 'spec_helper'

RSpec.describe Turnstile do
  let(:verify) { described_class::VERIFY_URI.to_s }
  let(:passed) do
    { success: true, hostname: described_class.hostname, action: 'contact' }
  end

  def answer(body, status: 200)
    stub_request(:post, verify).
      to_return(status: status, body: body.to_json,
                headers: { 'Content-Type' => 'application/json' })
  end

  def check(token = 'token', **options)
    described_class.check(token, action: 'contact', **options)
  end

  context 'with keys' do
    before do
      allow(AlaveteliConfiguration).to receive_messages(
        turnstile_site_key: 'site-key', turnstile_secret_key: 'secret-key'
      )
    end

    it 'passes a token made on this site for this form' do
      answer(passed)
      expect(check(remote_ip: '192.0.2.1')).to eq(:passed)
      sent = { secret: 'secret-key', response: 'token', remoteip: '192.0.2.1' }
      expect(a_request(:post, verify).with(
               body: sent,
               headers: {
                 'Content-Type' => 'application/x-www-form-urlencoded'
               }
             )).to have_been_made
    end

    it 'fails a token made on another site or for another form' do
      answer(passed.merge(hostname: 'staging.example.org'))
      expect(check).to eq(:failed)
      answer(passed.merge(action: 'signup'))
      expect(check).to eq(:failed)
    end

    it 'fails a token Cloudflare refuses, expired or used before' do
      answer({ 'success' => false,
               'error-codes' => ['invalid-input-response'] })
      expect(check).to eq(:failed)
      answer({ 'success' => false, 'error-codes' => ['timeout-or-duplicate'] })
      expect(check).to eq(:failed)
    end

    it 'fails a missing or overlong token without asking Cloudflare' do
      expect(check('')).to eq(:failed)
      expect(check('x' * 2049)).to eq(:failed)
      expect(a_request(:post, verify)).not_to have_been_made
    end

    it 'cannot answer when Cloudflare refuses the keys, and logs why' do
      answer({ 'success' => false, 'error-codes' => ['invalid-input-secret'] })
      logged = []
      allow(Rails.logger).to receive(:warn) { logged << _1 }
      expect(check).to eq(:unavailable)
      expect(logged.join).to include('invalid-input-secret')
      expect(logged.join).not_to include('secret-key')
    end

    it 'cannot answer when Cloudflare errs, is unreachable or unreadable' do
      answer({}, status: 500)
      expect(check).to eq(:unavailable)
      stub_request(:post, verify).to_timeout
      expect(check).to eq(:unavailable)
      stub_request(:post, verify).to_raise(Net::WriteTimeout)
      expect(check).to eq(:unavailable)
      answer(%w[not an answer])
      expect(check).to eq(:unavailable)
      stub_request(:post, verify).to_return(body: 'not json')
      expect(check).to eq(:unavailable)
    end
  end

  describe 'the "person check" health check' do
    let(:health_check) do
      HealthChecks.all.find { _1.success_message.include?('person check') }
    end

    it 'fails without keys outside development and test, passes with them' do
      allow(Rails.env).to receive(:local?).and_return(false)
      allow(AlaveteliConfiguration).to receive_messages(
        turnstile_site_key: '', turnstile_secret_key: ''
      )
      expect(health_check).not_to be_ok
      allow(AlaveteliConfiguration).to receive_messages(
        turnstile_site_key: 'site-key', turnstile_secret_key: 'secret-key'
      )
      expect(health_check).to be_ok
    end
  end

  context 'without keys' do
    before do
      allow(AlaveteliConfiguration).to receive_messages(
        turnstile_site_key: '', turnstile_secret_key: ''
      )
    end

    it 'is off in development and test' do
      expect(described_class).not_to be_configured
      expect(check(nil)).to eq(:passed)
    end

    it 'fails closed everywhere else' do
      allow(Rails.env).to receive(:local?).and_return(false)
      expect(check).to eq(:unavailable)
    end
  end
end
