require 'spec_helper'

RSpec.describe 'Admin two factor', type: :request do
  # Signing in enrols this admin, so it counts as one more with TOTP.
  before { sign_in FactoryBot.create(:admin_user) }

  let!(:ordinary) { FactoryBot.create(:user, :enable_totp) }
  let!(:enrolled) { FactoryBot.create(:admin_user, :enable_totp) }
  let!(:waiting) do
    FactoryBot.create(:admin_user, otp_required_for_login: true)
  end

  let(:page) { Nokogiri::HTML(response.body) }

  def totp_counts
    row = page.xpath("//tr[td[text()='Authenticator enabled']]")
    row.css('td.text-right').map { |cell| cell.text.strip }
  end

  def unenrolled_links
    page.xpath("//h2[text()='Admins awaiting enrolment']/" \
               'following-sibling::table[1]//a').map { |link| link['href'] }
  end

  it 'reports current enrolment without treating old HOTP data as a factor' do
    waiting.update_columns(otp_enabled: true,
                           otp_secret_key: 'invented-legacy-secret')
    get admin_two_factor_path
    expect(response).to have_http_status(:ok)
    expect(totp_counts).to eq(%w[3 2])
    expect(unenrolled_links).to include(admin_user_path(waiting))
    expect(unenrolled_links).not_to include(admin_user_path(enrolled))
  end

  it 'lists admins who have never signed in in the order they joined' do
    never = FactoryBot.create_list(:admin_user, 3,
                                   otp_required_for_login: true)
    # A row that is changed moves in the table.
    never.first.update_columns(locale: 'en')
    get admin_two_factor_path

    expected = never.map { |user| admin_user_path(user) }
    expect(unenrolled_links & expected).to eq(expected)
  end
end
