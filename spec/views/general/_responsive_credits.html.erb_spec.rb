require 'spec_helper'

RSpec.describe 'general/_responsive_credits' do
  before { render }

  it 'credits Nedervetil' do
    expect(rendered).to have_content('Powered by Nedervetil')
  end

  it 'links to the source code' do
    expect(rendered).
      to have_link('Nedervetil', href: 'https://github.com/FOIMonkey/nedervetil-app')
  end
end
