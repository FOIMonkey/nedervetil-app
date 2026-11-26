require 'spec_helper'
RSpec.describe IncomingAttention::Client do
  before { allow(IncomingAttention::Config).to receive(:enabled?).and_return(true) }
  let(:input) { bounded_input }
  def result
    bounded_worker_response(
      input,
      labels: { 'routine' => 'ACKNOWLEDGEMENT', 'attention' => 'SUBSTANTIVE' }
    )
  end

  def classify(value, status: 200)
    described_class.new(transport: ->(_) { [status, JSON.generate(value)] }).
      classify(input)
  end
  it 'accepts a route and labels, and ignores deployment identity and diagnostics it does not read' do
    value = result.merge('worker_release' => 'a-new-release', 'extra' => true)
    expect(classify(value)).to eq(value)
  end
  %w[message_id info_request_id contract_version].each do |key|
    it "rejects wrong #{key}" do
      expect { classify(result.merge(key => 'wrong')) }.
        to raise_error(described_class::Error)
    end
  end
  it 'rejects invalid routes, labels and diagnostics' do
    expect { classify(result.merge('route' => 'ROUTINE')) }.
      to raise_error(described_class::Error)
    expect {
      classify(result.merge('labels' => { 'routine' => 'RECEIPT',
                                          'attention' => nil }))
    }.to raise_error(described_class::Error)
    expect { classify(result.merge('labels' => { 'routine' => nil })) }.
      to raise_error(described_class::Error)
    expect { classify(result.merge('diagnostics' => 'scores')) }.
      to raise_error(described_class::Error)
  end
  it 'forbids eligibility on shortened input and requires the Worker to see a shortened reply as such' do
    allow(self).
      to receive(:input).and_return(bounded_input('Long reply ' * 2000))
    expect { classify(result.merge('eligibility' => true)) }.
      to raise_error(described_class::Error)
    expect {
      classify(result.merge('input_truncated' => false, 'eligibility' => false))
    }.to raise_error(described_class::Error)
  end
  it 'accepts fixed Worker errors without labels' do
    error = input.slice(
      'contract_version',
      'message_id',
      'info_request_id'
    ).merge('inference_status' => 'unavailable',
            'route' => 'REVIEW',
            'needs_check' => true,
            'eligibility' => false,
            'input_truncated' => nil,
            'labels' => nil,
            'diagnostics' => nil,
            'error_code' => 'provider_timeout')
    expect(classify(error, status: 504)['error_code']).to eq('provider_timeout')
    expect { classify(error.merge('labels' => {}), status: 504) }.
      to raise_error(described_class::Error)
  end
  it 'keeps errors fixed and enforces response size' do
    client = described_class.new(
      transport: ->(_) { raise 'SECRET EMAIL CONTENT' }
    )
    allow(Rails.logger).to receive(:warn).and_call_original
    expect { client.classify(input) }.
      to raise_error(described_class::Error, 'transport_failure')
    expect(Rails.logger).to have_received(:warn).
      with('incoming_attention_classify_failed RuntimeError')
    client = described_class.new(transport: ->(_) { [200, 'a' * 131073] })
    expect { client.classify(input) }.
      to raise_error(described_class::Error, 'response_limit')
  end
  it 'rejects insecure or unconfigured endpoints before connecting' do
    allow(IncomingAttention::Config).to receive(:endpoint).and_return('http://example.invalid/v1/classify')
    expect(Net::HTTP).not_to receive(:new)
    expect { described_class.new.classify(input) }.
      to raise_error(described_class::Error, 'worker_unconfigured')
  end
  it 'carries no question wording, model or threshold' do
    source = Dir[Rails.root.join(
      '{app/*,lib}/incoming_attention/**/*.rb'
    )].map { |path|
      File.read(path)
    }.join
    expect(source).
      not_to include('@cf/cloudflare',
                     'Does this reply',
                     'instructions',
                     'CLEAR_SOME')
    expect(
      Dir[Rails.root.join('{app/*,lib}/incoming_attention/**/schema.json')]
    ).to be_empty
  end
end
