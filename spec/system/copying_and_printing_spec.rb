require 'spec_helper'
require 'integration/alaveteli_dsl'

# The clipboard and print controllers, which replaced ClipboardJS and a
# print handler in snippets.js. The browser's own clipboard and print
# dialog are stood in for, so the spec sees what the page asked for.
RSpec.describe 'Copying and printing', js: true do
  def stand_in_for_the_browser
    page.execute_script(<<~JS)
      window.copied = null
      Object.defineProperty(navigator, 'clipboard', {
        configurable: true,
        value: { writeText: (text) => { window.copied = text; return Promise.resolve() } }
      })
      window.printed = false
      window.print = () => { window.printed = true }
    JS
  end

  describe 'backup codes' do
    let(:user) { FactoryBot.create(:user) }

    before do
      allow(AlaveteliConfiguration).
        to receive(:enable_two_factor_auth).and_return(true)
    end

    def enrol
      visit new_one_time_password_path
      fill_in 'Current password', with: 'jonespassword'
      click_button 'Continue'
      secret = find('p code').text
      fill_in 'Authenticator code',
              with: ROTP::TOTP.new(secret).now
      click_button 'Enable two factor authentication'
      expect(page).to have_content('Save these codes somewhere safe')
    end

    it 'copies them and says so' do
      using_session(login(user)) do
        enrol
        stand_in_for_the_browser
        codes = all('.backup-codes__list code').map(&:text)
        click_button 'Copy codes'
        expect(page).to have_button('Copied!')
        expect(page.evaluate_script('window.copied')).to eq(codes.join("\n"))
      end
    end

    it 'prints them' do
      using_session(login(user)) do
        enrol
        stand_in_for_the_browser
        click_link 'Print codes'
        expect(page.evaluate_script('window.printed')).to be true
      end
    end
  end
end
