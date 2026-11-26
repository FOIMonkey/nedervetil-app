require 'spec_helper'

# A record's tags come back in the order they were added, which is the order
# of its tag string. The database promises no order of its own: a row that
# is changed moves in the table.
RSpec.describe 'The order of a record’s tags' do
  let(:authority) do
    FactoryBot.create(:public_body, tag_string: 'first second third')
  end

  it 'is the order they were added, after one of them is changed' do
    authority.tags.first.update!(value: 'changed')

    expect(authority.reload.tags.map(&:name)).to eq(%w[first second third])
    expect(authority.reload.tag_string).to eq('first:changed second third')
  end
end
