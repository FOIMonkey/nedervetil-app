# config/test.yml has AI reading on, as most specs expect. Specs that need it
# off include this; true turns it back on inside a group that has it off.
RSpec.shared_context 'with incoming attention off' do |value = false|
  before do
    allow(AlaveteliConfiguration).
      to receive(:incoming_attention_enabled).and_return(value)
  end
end
