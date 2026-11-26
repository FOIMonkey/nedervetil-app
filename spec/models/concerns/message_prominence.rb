RSpec.shared_examples 'concerns/message_prominence' do |*factory_opts|
  let(:record) { FactoryBot.build(*factory_opts) }

  describe 'when validating' do
    it 'should be valid with its class\'s prominence values' do
      record.class.prominence_states.each do |prominence|
        record.prominence = prominence
        expect(record.valid?).to be true
      end
    end

    it 'should not be valid with any other prominence value' do
      (%w[normal requester_only hidden invalid] -
        record.class.prominence_states).each do |prominence|
        record.prominence = prominence
        expect(record.valid?).to be false
      end
    end
  end

  describe 'when asked if it is public' do
    subject { record.is_public? }

    it 'should return false if it has prominence "hidden"' do
      record.prominence = 'hidden'
      is_expected.to be false
    end

    it 'should return false if it has prominence "requester_only"' do
      record.prominence = 'requester_only'
      is_expected.to be false
    end

    it 'should return true if it has its public prominence' do
      public_state = (record.class.prominence_states -
                      %w[hidden requester_only]).first || 'normal'
      record.prominence = public_state
      is_expected.to be true
    end
  end
end
