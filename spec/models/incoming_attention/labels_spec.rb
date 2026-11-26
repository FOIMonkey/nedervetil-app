require 'spec_helper'

RSpec.describe IncomingAttention::Labels do
  include_context 'with lean attention predictions'
  let(:user) { FactoryBot.create(:pro_user) }
  let(:request) { FactoryBot.create(:info_request, user: user) }
  let(:message) { lean_response(request, 'REVIEW') }
  let(:prediction) { IncomingAttention::Prediction.for_message(message) }

  def labels(routine: nil, attention: nil)
    prediction.update!(reply_labels: { 'routine' => routine,
                                       'attention' => attention })
  end

  it "uses the Worker's substantive label while leaving route and human outcomes untouched" do
    labels(attention: 'SUBSTANTIVE')
    expect(described_class.for_message(message)).to eq('Substantive response')
    expect(prediction.reload.route).to eq('REVIEW')
    expect(request.reload.described_state).to eq('waiting_response')
  end

  it 'names action, delivery and procedural replies' do
    labels(attention: 'ACTION_REQUESTED')
    expect(described_class.for_message(message)).
      to eq('Reply or action requested')
    labels(attention: 'DELIVERY_PROBLEM')
    expect(described_class.for_message(message)).to eq('Delivery problem')
    labels(attention: 'DECISION')
    expect(described_class.for_message(message)).
      to eq('Likely decision or review response')
  end

  it 'falls back for missing, unknown, shortened, stale and older labels' do
    labels
    expect(described_class.for_message(message)).to eq('Other reply to review')
    labels(attention: 'SOMETHING_NEW')
    expect(described_class.for_message(message)).to eq('Other reply to review')
    labels(attention: 'SUBSTANTIVE')
    prediction.update!(restrictions: ['input_truncated'])
    expect(described_class.for_message(message)).to eq('Other reply to review')
    prediction.update!(restrictions: [],
                       reply_labels: nil,
                       native_response: { 'answers' => {} })
    expect(described_class.for_message(message)).to eq('Other reply to review')
    labels(attention: 'SUBSTANTIVE')
    prediction.invalidate!
    expect(described_class.for_message(message)).to eq('Other reply to review')
  end

  it "uses the label for the reply's current bucket and never turns it into routine eligibility" do
    labels(routine: 'ACKNOWLEDGEMENT', attention: 'SUBSTANTIVE')
    expect(described_class.for_message(message)).to eq('Substantive response')
    expect(IncomingAttention::Effective.routine?(message)).to eq(false)
    lean_prediction(message, 'SKIP')
    expect(described_class.for_message(message)).to eq('Acknowledgement')
  end

  it 'tells a routine reply by its kind, so a reworded label is still routine' do
    routine = lean_response(request, 'SKIP')
    IncomingAttention::Prediction.for_message(routine).
      update!(reply_labels: { 'routine' => 'ACKNOWLEDGEMENT' })
    stub_const('IncomingAttention::Labels::ROUTINE',
               { 'ACKNOWLEDGEMENT' => 'Receipt' })
    expect(described_class.for_message(routine)).to eq('Receipt')
    expect(described_class.routine?(routine)).to be true
    labels(attention: 'SUBSTANTIVE')
    expect(described_class.routine?(message)).to be false
  end

  it 'puts an outcome label first, so that reply is not routine' do
    routine = lean_response(request, 'SKIP')
    allow(IncomingAttention::Outcome).
      to receive(:label).and_return('All information released')
    expect(described_class.for_message(routine)).
      to eq('All information released')
    expect(described_class.routine?(routine)).to be false
  end
end
