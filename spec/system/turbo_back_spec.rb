require 'spec_helper'
require 'integration/alaveteli_dsl'

# Open-state examples leave via Forward: clicking a link would close menus
# before Turbo caches the snapshot.
RSpec.describe 'Back and Forward with Turbo Drive', js: true do
  # The footer's contact link, in core and in both themes.
  def leave_by_link
    expect_turbo_visit { find("#footer a[href='#{help_contact_path}']").click }
  end

  # Signed-in pages disable Turbo caching; strip the meta tag so controllers
  # are still exercised on cached snapshots.
  def let_turbo_keep_a_copy
    page.execute_script(<<~JS)
      document.querySelector('meta[name="turbo-cache-control"]')?.remove();
    JS
  end

  def round_trip
    leave_by_link
    go_back_with_turbo
  end

  def sign_in(user)
    if user.is_admin? && !user.totp?
      user.update!(otp_secret: User.generate_otp_secret,
                   otp_required_for_login: true)
    end
    visit signin_path
    within '#signin_form' do
      fill_in 'user_signin_email', with: user.email
      fill_in 'user_signin_password', with: 'jonespassword'
      fill_in 'user_signin_otp_attempt', with: user.current_otp if user.totp?
      click_button(name: 'commit')
    end
    expect(page).to have_no_css('#signin_form')
  end

  let(:admin) { FactoryBot.create(:admin_user) }

  describe 'a request page' do
    let(:info_request) { FactoryBot.create(:info_request) }

    let!(:incoming) do
      FactoryBot.create(
        :incoming_message,
        info_request: info_request,
        foi_attachments_factories: Array.new(2) { [:pdf_attachment] }
      ).tap do |message|
        info_request.log_event('response', incoming_message_id: message.id)
      end
    end

    let(:outgoing) { info_request.outgoing_messages.first }

    # The private archive shows a request's classic page to an admin.
    before { sign_in(admin) }

    def outgoing_message
      find('.outgoing.correspondence')
    end

    it 'shows the gaps, the attachments list and the step buttons once' do
      visit show_request_path(info_request.url_title)
      let_turbo_keep_a_copy
      expect(page).to have_css('.thread-gap')
      gaps = all('.thread-gap').size

      round_trip
      expect(page).to have_css('.thread-gap', count: gaps)
      expect(page).to have_css('#right_column .sidebar__documents',
                               count: 1, visible: :all)
    end

    # Same-page hash navigation still caches a Turbo snapshot for Back.
    it 'shows the gaps and the attachments list once around a same-page link' do
      visit show_request_path(info_request.url_title)
      let_turbo_keep_a_copy
      expect(page).to have_css('.thread-gap')
      gaps = all('.thread-gap').size

      # As a keyboard user does: the link shows only once it has focus.
      page.execute_script("document.querySelector('.skip-to-link').focus()")
      page.driver.browser.keyboard.type(:Enter)
      expect(page).to have_current_path(/#content\z/, url: true)
      expect(page).to have_css('.thread-gap', count: gaps)
      expect(page).to have_css('#right_column .sidebar__documents',
                               count: 1, visible: :all)

      # Turbo stores its copy a moment after the address changes.
      stored = eventually do
        page.evaluate_script(
          'Boolean(Turbo.session.view.getCachedSnapshotForLocation(' \
          'new URL(location.href)))'
        )
      end
      expect(stored).to be(true)
      go_back_with_turbo
      expect(page).to have_css('.thread-gap', count: gaps)
      expect(page).to have_css('#right_column .sidebar__documents',
                               count: 1, visible: :all)
    end

    it 'shuts the Actions menu' do
      visit show_request_path(info_request.url_title)
      let_turbo_keep_a_copy
      round_trip

      menu = first('.after-actions__action-menu')
      menu.find('.action-menu__button').click
      expect(menu).to have_css('.action-menu__menu', visible: :visible)

      go_forward_with_turbo
      go_back_with_turbo
      menu = first('.after-actions__action-menu')
      expect(menu).to have_no_css('.action-menu__menu', visible: :visible)
      expect(menu.find('.action-menu__button')['aria-expanded']).to eq('false')
    end

    it 'hides the mail server’s log' do
      visit show_request_path(info_request.url_title)
      let_turbo_keep_a_copy
      round_trip

      # The optional mail add-on deliberately has no server-log UI.
      site_hides_delivery_log = false
      if site_hides_delivery_log
        expect(outgoing_message).
          to have_no_css('.toggle-delivery-log, .correspondence_delivery',
                         visible: :all)
      else
        outgoing_message.find('.toggle-delivery-log').click
        expect(outgoing_message).to have_css('.correspondence_delivery')
      end

      go_forward_with_turbo
      go_back_with_turbo
      expect(outgoing_message).to have_no_css('.correspondence_delivery')
      if site_hides_delivery_log
        expect(outgoing_message).
          to have_no_css('.toggle-delivery-log', visible: :all)
      else
        expect(outgoing_message.find('.toggle-delivery-log')['aria-expanded']).
          to eq('false')
      end
    end
  end

  describe 'the header' do
    before { sign_in(admin) }

    it 'shuts the account menu and the admin bar’s Tools menu' do
      visit help_about_path
      round_trip

      find('#logged_in_bar .account-link').click
      expect(page).to have_css('.logged-in-menu', visible: :visible)
      find('details.admin-bar__more summary.admin-bar__toggle').click
      expect(page).to have_css('details.admin-bar__more[open]')

      go_forward_with_turbo
      go_back_with_turbo
      expect(page).to have_no_css('.logged-in-menu', visible: :visible)
      expect(find('#logged_in_bar .account-link')['aria-expanded']).
        to eq('false')
      expect(page).to have_no_css('details.admin-bar__more[open]')
    end
  end

  # Signed in to bypass Turnstile (which opts out of Drive); cache the
  # destination page so Back checks that flash notices are cleared.
  describe 'a form' do
    it 'gives the buttons back after the form sent, and no old notice' do
      sign_in(FactoryBot.create(:user))
      visit new_change_request_path
      # The label names another id, so the field goes by its own.
      fill_in 'public_body_change_request_public_body_name',
              with: 'Department of Hats'
      button = find('input[type="submit"][data-disable-with]')
      words = button.value
      expect_turbo_visit { button.click }
      expect(page).to have_current_path(alaveteli_pro_dashboard_path)

      let_turbo_keep_a_copy
      round_trip
      expect(page).to have_no_css('#notice')

      go_back_with_turbo
      expect(page).to have_current_path(new_change_request_path)
      button = find('input[type="submit"][data-disable-with]')
      expect(button).not_to be_disabled
      expect(button.value).to eq(words)
    end
  end

  describe 'a topic page' do
    before do
      allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
      allow(AlaveteliFeatures.backend).to receive(:enabled?).
        with(:alaveteli_pro).and_return(true)
    end

    let(:topic) { Topics::Topic.all.first }

    it 'goes back from a question’s page to its topic' do
      entry = Topics::Guide.new(topic, 'england').entries.first
      visit topic_path(topic.slug)
      find('.topic-sorted a', text: entry.question.text).click
      question = topic_question_path(topic.slug, entry.slug)
      expect(page).to have_current_path(question)
      expect(find('#content h1').text).to eq(entry.question.text)

      leave_by_link
      go_back_with_turbo
      expect(page).to have_current_path(question)
      expect(find('#content h1').text).to eq(entry.question.text)

      go_back_with_turbo
      expect(page).to have_current_path(topic_path(topic.slug))
      expect(find('#content h1').text).to eq(topic.title)
    end
  end

  describe 'a document page' do
    include ActiveJob::TestHelper
    include DisclosuresHelpers
    include_context 'with document OCR off'

    let(:owner) { FactoryBot.create(:user, trusted: true) }
    let(:info_request) { FactoryBot.create(:info_request, user: owner) }

    # A letter with words on its pages, so the page offers the Text view.
    let(:document) do
      pages = [AttachmentFixtures.letter_page(secret: 'Pothole repairs')]
      document = delivered_document(info_request, 'letter.pdf',
                                    'application/pdf',
                                    AttachmentFixtures.pdf(pages: pages),
                                    by: owner, kind: 'decision_letter')
      publish(document, by: admin)
      document.reload
    end

    # The swap rewrites the address in place; Back needs the entry to keep
    # Turbo's state, or Turbo leaves the page it came from on screen.
    it 'comes Back to the view that was chosen' do
      visit "/documents/#{document.public_id}"
      find('.document-views__link[data-document-view="text"]').click
      expect(page).to have_current_path(/view=text/)

      leave_by_link
      go_back_with_turbo
      expect(page).to have_current_path(/view=text/)
      expect(page).to have_css('.document-views')
    end
  end
end
