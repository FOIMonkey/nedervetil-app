require 'spec_helper'

# An admin may erase any closed account that isn't banned
# (User#erasable?); the button follows that rule.
RSpec.describe 'The Erase button on an account', type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:account) { FactoryBot.create(:user) }

  # config/test.yml trusts everyone as an admin unless told otherwise.
  before do
    allow(AlaveteliConfiguration).to receive(:skip_admin_auth).and_return(false)
    sign_in(admin)
  end

  def erase_button
    get "/admin/users/#{account.id}/edit"
    form = "form[action='/admin/users/#{account.id}/erasure']"
    Nokogiri::HTML(response.body).at_css("#{form} input[type=submit]")
  end

  it 'is enabled for a closed account' do
    account.close!
    expect(erase_button['disabled']).to be_nil
  end

  it 'is disabled for a closed account that is banned' do
    account.update!(ban_text: 'Spam')
    account.close!
    expect(erase_button['disabled']).to be_present
  end

  it 'is disabled while the account is open' do
    expect(erase_button['disabled']).to be_present
  end
end
