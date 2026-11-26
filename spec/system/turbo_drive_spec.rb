require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'Turbo Drive', js: true do
  # The footer's contact link, in core and in both themes.
  def click_contact_link
    find("#footer a[href='#{help_contact_path}']").click
  end

  def opt_out(*actions)
    allow_any_instance_of(HelpController).
      to receive(:turbo_drive?) { |c| !actions.include?(c.action_name.to_sym) }
  end

  it 'is on for the public site, and full Turbo Drive is off on admin pages' do
    visit help_about_path
    expect(page.evaluate_script('Turbo.session.drive')).to be(true)

    using_session(login(FactoryBot.create(:admin_user))) do
      visit admin_request_path(FactoryBot.create(:info_request))
      expect(page).to have_css('#content, .container', match: :first)
      expect(page.evaluate_script('Turbo.session.drive')).to be(false)
      expect_full_load { find('#admin-bar a', text: 'Users').click }
    end
  end

  it 'follows a link with a Turbo visit, and Back restores the page' do
    visit help_about_path
    expect_turbo_visit { click_contact_link }
    expect(page).to have_current_path(help_contact_path)

    go_back_with_turbo
    expect(page).to have_current_path(help_about_path)
  end

  it 'loads a page on the opt-out list in full when a Turbo visit lands on it' do
    opt_out(:contact)
    visit help_about_path
    expect_full_load { click_contact_link }
    expect(page).to have_current_path(help_contact_path)
  end

  it 'loads in full from links on a page on the opt-out list' do
    opt_out(:about)
    visit help_about_path
    expect_full_load { click_contact_link }
    expect(page).to have_current_path(help_contact_path)
  end

  # Turbo only renders 422 failures (not 200). Signed in to bypass Turnstile,
  # which opts the page out of Drive.
  it "shows a failed form's errors without a full page load" do
    using_session(login(FactoryBot.create(:user))) do
      visit new_change_request_path
      expect_turbo_visit { click_button 'Submit request' }
      expect(page).to have_css('#errorExplanation')
    end
  end

  # Turbo creates the new page's scripts from its own code, and the CSP's
  # 'strict-dynamic' would trust them all (helpers/turbo_script_guard.js).
  it 'runs only the body scripts the page was sent with its nonce' do
    allow_any_instance_of(HelpController).to receive(:contact) do |c|
      nonce = c.send(:content_security_policy_nonce)
      # rubocop:disable Rails/OutputSafety -- the spec's own page, with the request's nonce
      c.render layout: 'default', html: <<~HTML.html_safe
        <p id="script-probe">Probe</p>
        <script nonce="#{nonce}">window.noncedScriptRan = true</script>
        <script>window.injectedScriptRan = true</script>
      HTML
      # rubocop:enable Rails/OutputSafety
    end

    visit help_about_path
    expect_turbo_visit { click_contact_link }
    expect(page).to have_css('#script-probe')
    expect(page.evaluate_script('window.noncedScriptRan')).to be(true)
    expect(page.evaluate_script('window.injectedScriptRan')).to be_nil
  end
end
