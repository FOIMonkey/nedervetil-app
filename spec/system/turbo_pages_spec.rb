require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'The public site under Turbo Drive', js: true do
  before do
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    allow(AlaveteliFeatures.backend).to receive(:enabled?).
      with(:alaveteli_pro).and_return(true)
  end

  # Wrapped in <p> because a theme can hide a bare link in #content.
  def add_plain_link_to(path)
    page.execute_script(<<~JS, path)
      const link = document.createElement('a');
      link.href = arguments[0];
      link.id = 'plain-link';
      link.textContent = 'Plain link';
      const para = document.createElement('p');
      para.append(link);
      document.querySelector('#content').append(para);
    JS
  end

  def nav_link(path)
    find("a[href='#{path}']", match: :first)
  end

  def announced
    page.evaluate_script(
      "document.getElementById('page-announcer').textContent"
    )
  end

  def active_element
    page.evaluate_script(
      'document.activeElement.id || document.activeElement.tagName'
    )
  end

  # Hold just the controller's fetch, including a response already queued when
  # abort fires. Navigation and the page's other requests still use the network.
  def hold_waiting_fetches(url)
    page.execute_script(<<~JS, url)
      const waiting = new URL(arguments[0], location.href).href;
      window.waitingOnly = document.querySelector('[data-publish-wait]')?.getAttribute('data-publish-only');
      const original = window.fetch;
      window.waitingFetches = [];
      window.waitingVisits = 0;
      document.addEventListener('turbo:before-visit', () => { window.waitingVisits += 1 });
      window.fetch = (resource, options = {}) => {
        if (new URL(String(resource), location.href).href !== waiting) {
          return original(resource, options);
        }
        return new Promise((resolve, reject) => {
          window.waitingFetches.push({ resolve, reject, signal: options.signal });
        });
      };
    JS
  end

  def waiting_fetch_count
    page.evaluate_script('window.waitingFetches.length')
  end

  def disconnect_waiting_controller(identifier)
    page.execute_script(<<~JS, identifier)
      window.waitingElement = document.querySelector(`[data-controller~="${arguments[0]}"]`);
      window.waitingController = Stimulus.getControllerForElementAndIdentifier(window.waitingElement, arguments[0]);
      window.waitingElement.remove();
    JS
    disconnected = eventually do
      page.evaluate_script(
        "!Stimulus.getControllerForElementAndIdentifier(" \
        "window.waitingElement, '#{identifier}')"
      )
    end
    expect(disconnected).to be(true)
  end

  def reconnect_waiting_controller(identifier)
    page.execute_script(
      "document.getElementById('content').append(window.waitingElement)"
    )
    reconnected = eventually do
      page.evaluate_script(
        "Stimulus.getControllerForElementAndIdentifier(" \
        "window.waitingElement, '#{identifier}') === window.waitingController"
      )
    end
    expect(reconnected).to be(true)
  end

  it 'moves between the home page, topics, documents, authorities and help by Turbo visits' do
    visit frontpage_path
    expect_turbo_visit { nav_link(topics_path).click }
    expect(page).to have_current_path(topics_path)
    expect_turbo_visit { nav_link(disclosure_documents_path).click }
    expect(page).to have_current_path(disclosure_documents_path)
    # /groups may redirect to the full list, depending on the data.
    expect_turbo_visit { nav_link(authority_groups_path).click }
    authorities = page.current_path
    expect(authorities).to match(%r{\A/(groups|body/list/all)\z})
    expect_turbo_visit { nav_link(help_about_path).click }
    expect(page).to have_current_path(help_about_path)

    go_back_with_turbo
    expect(page).to have_current_path(authorities)
    go_back_with_turbo
    expect(page).to have_current_path(disclosure_documents_path)
  end

  describe 'a Drive visit, for keyboard and screen reader users' do
    it 'keeps navigation and keyboard menus working through repeated visits and Back' do
      using_session(login(FactoryBot.create(:user))) do
        visit help_about_path
        3.times do
          expect_turbo_visit { nav_link(disclosure_documents_path).click }
          expect(active_element).to eq('BODY')
          page.driver.browser.keyboard.type(:Tab)
          focused = page.evaluate_script(
            'document.activeElement.classList.contains("skip-to-link")'
          )
          expect(focused).to be(true)
          go_back_with_turbo
          expect(page).to have_current_path(help_about_path)
          title = page.evaluate_script('document.title')
          expect(eventually { announced == title }).to be(true)
          link = find('#logged_in_bar .account-link')
          page.execute_script(
            "document.querySelector('#logged_in_bar .account-link').focus()"
          )
          page.driver.browser.keyboard.type(:Enter)
          expect(page).
            to have_css('.logged-in-menu', visible: :visible, count: 1)
          link.send_keys(:escape)
          expect(page).to have_no_css('.logged-in-menu', visible: :visible)
          focused = page.evaluate_script(
            'document.activeElement.classList.contains("account-link")'
          )
          expect(focused).to be(true)
        end
      end
    end

    # Submitting redirects via the home page to the Pro dashboard.
    it 'keeps entered words through repeated errors, then clears the errors after correction' do
      using_session(login(FactoryBot.create(:user))) do
        visit new_change_request_path
        words = 'Please add the transport office.'
        fill_in 'public_body_change_request_notes', with: words
        3.times do
          expect_turbo_visit { click_button 'Submit request' }
          expect(page).to have_css('#errorExplanation', count: 1)
          expect(eventually { active_element == 'errorExplanation' }).
            to be(true)
          expect(page).to have_field('public_body_change_request_notes',
                                     with: words)
          expect(find('input[type="submit"]')).not_to be_disabled
        end
        fill_in 'public_body_change_request_public_body_name',
                with: 'Transport Office'
        expect_turbo_visit { click_button 'Submit request' }
        expect(page).to have_current_path(alaveteli_pro_dashboard_path)
        expect(page).to have_no_css('#errorExplanation')
        expect(active_element).to eq('BODY')
        page.driver.browser.keyboard.type(:Tab)
        focused = page.evaluate_script(
          'document.activeElement.classList.contains("skip-to-link")'
        )
        expect(focused).to be(true)
        go_back_with_turbo
        expect(page).to have_current_path(new_change_request_path)
        expect(page).to have_no_css('#errorExplanation')
        expect(find('input[type="submit"]')).not_to be_disabled
      end
    end

    it 'reads out the new title and starts the next Tab at the top' do
      visit help_about_path
      expect_turbo_visit { nav_link(disclosure_documents_path).click }

      title = page.evaluate_script('document.title')
      expect(eventually { announced == title }).to be(true)
      expect(active_element).to eq('BODY')

      page.driver.browser.keyboard.type(:Tab)
      focused = page.evaluate_script(
        'document.activeElement.classList.contains("skip-to-link")'
      )
      expect(focused).to be(true)
    end

    it 'reads out the title on Back, leaving focus alone' do
      visit help_about_path
      expect_turbo_visit { nav_link(disclosure_documents_path).click }
      go_back_with_turbo

      title = page.evaluate_script('document.title')
      expect(eventually { announced == title }).to be(true)
      expect(page.evaluate_script('document.body.hasAttribute("tabindex")')).
        to be(false)
    end

    # Signed in, as a visitor sees the person check there (turnstile_box).
    it 'focuses the error summary after a failed submit' do
      using_session(login(FactoryBot.create(:user))) do
        visit new_change_request_path
        expect_turbo_visit { click_button 'Submit request' }
        expect(page).to have_css('#errorExplanation')
        expect(eventually { active_element == 'errorExplanation' }).to be(true)
      end
    end

    # Back after a link to a place on the page is a Turbo restoration visit.
    # It mustn't leave its mark on the next submit.
    it 'focuses the error summary after Back from a link to a place on the page' do
      using_session(login(FactoryBot.create(:user))) do
        visit new_change_request_path
        page.execute_script("document.querySelector('.skip-to-link').focus()")
        page.driver.browser.keyboard.type(:Enter)
        expect(page).to have_current_path(/#content\z/, url: true)
        page.go_back
        expect(page).to have_no_current_path(/#content\z/, url: true)

        expect_turbo_visit { click_button 'Submit request' }
        expect(page).to have_css('#errorExplanation')
        expect(eventually { active_element == 'errorExplanation' }).to be(true)
      end
    end

    it 'loads a page showing the person check in full' do
      allow(Turnstile).to receive_messages(configured?: true,
                                           site_key: 'site-key')
      visit help_about_path
      add_plain_link_to(new_change_request_path)
      # The themes hide links to this page from visitors, cosmetically.
      expect_full_load do
        find_by_id('plain-link', visible: :all).trigger('click')
      end
      expect(page).to have_css('.cf-turnstile', visible: :all)
    end
  end

  it 'asks the server again on Back to a page rendered for someone signed in' do
    user = FactoryBot.create(:user, name: 'Quentin Privateperson')
    visit signin_path
    within '#signin_form' do
      fill_in 'user_signin_email', with: user.email
      fill_in 'user_signin_password', with: 'jonespassword'
      click_button(name: 'commit')
    end
    expect(page).to have_no_css('#signin_form')

    visit show_user_profile_path(url_name: user.url_name)
    expect(page).to have_css('#content', text: 'Quentin Privateperson')
    expect_turbo_visit { nav_link(help_about_path).click }

    first_tab = current_window
    second_tab = open_new_window
    within_window(second_tab) do
      visit help_about_path
      find('#logged_in_bar .account-link').click
      click_link 'Sign out'
      expect(page).to have_no_css('#logged_in_bar .account-link')
    end
    second_tab.close
    switch_to_window(first_tab)

    page.execute_script('document.body.dataset.leftBehind = "yes"')
    page.go_back
    expect(page).to have_current_path(
      show_user_profile_path(url_name: user.url_name)
    )
    expect(page).to have_no_css('body[data-left-behind]')
    expect(page).to have_no_content('Quentin Privateperson')
  end

  # Turbo 8 would fetch the page again for a link to a place on it.
  it 'leaves a link to a place on the same page to the browser' do
    visit help_about_path
    page.execute_script(<<~JS)
      window.turboSpecMarker = true;
      window.turboSpecVisits = 0;
      document.addEventListener('turbo:visit', () => { window.turboSpecVisits += 1 });
    JS
    page.execute_script("document.querySelector('.skip-to-link').focus()")
    page.driver.browser.keyboard.type(:Enter)
    expect(page).to have_current_path(/#content\z/, url: true)
    state = page.evaluate_script(
      '[window.turboSpecMarker, window.turboSpecVisits]'
    )
    expect(state).to eq([true, 0])
  end

  describe 'the request flows' do
    it 'reaches signing in, password reset and the new request flow by Turbo visits' do
      paths = [signin_path, new_password_change_path, select_authority_path]
      paths.each do |path|
        visit help_about_path
        add_plain_link_to(path)
        expect_turbo_visit { find_by_id('plain-link').click }
        expect(page).to have_current_path(path)
      end
    end

    it 'signs in by a full page load' do
      user = FactoryBot.create(:user)
      visit help_about_path
      add_plain_link_to(signin_path)
      expect_turbo_visit { find_by_id('plain-link').click }
      within '#signin_form' do
        fill_in 'user_signin_email', with: user.email
        fill_in 'user_signin_password', with: 'jonespassword'
      end
      expect_full_load { find("#signin_form input[name='commit']").click }
      expect(page).to have_no_css('#signin_form')
    end

    it 'requires the password and second factor together and finishes with a full load' do
      user = FactoryBot.create(:user, :enable_totp)
      visit signin_path
      within '#signin_form' do
        fill_in 'user_signin_email', with: user.email
        fill_in 'user_signin_password', with: 'jonespassword'
      end
      expect_full_load { find("#signin_form input[name='commit']").click }
      expect(page).to have_css('#signin_form')
      expect(page).to have_no_css('#logged_in_bar .account-link')
      within '#signin_form' do
        fill_in 'user_signin_password', with: 'jonespassword'
        fill_in 'user_signin_otp_attempt', with: user.current_otp
      end
      expect_full_load { find("#signin_form input[name='commit']").click }
      expect(page).to have_css('#logged_in_bar .account-link')
    end

    it 'reaches a request page by a Turbo visit, and loads the box editor in full' do
      info_request = FactoryBot.create(:info_request)
      incoming = FactoryBot.create(
        :incoming_message, info_request: info_request,
                           foi_attachments_factories: [[:pdf_attachment]]
      )
      attachment = incoming.foi_attachments.first
      using_session(login(FactoryBot.create(:admin_user))) do
        visit help_about_path
        add_plain_link_to(show_request_path(info_request.url_title))
        expect_turbo_visit { find_by_id('plain-link').click }
        expect(page).to have_css('#left_column')

        add_plain_link_to(manage_attachment_path(attachment))
        expect_left_to_browser { find_by_id('plain-link').click }
      end
    end

    # A Drive visit to them would only load them again in full.
    it 'leaves links to the writing pages and admin to the browser' do
      info_request = FactoryBot.create(:info_request)
      using_session(login(FactoryBot.create(:admin_user))) do
        [new_request_followup_path(info_request.url_title),
         admin_general_index_path].each do |path|
          visit help_about_path
          add_plain_link_to(path)
          expect_left_to_browser { find_by_id('plain-link').click }
        end
      end
    end

    it 'reaches Pro’s dashboard and requests by Turbo visits, and its request form in full' do
      allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
      allow(AlaveteliFeatures.backend).to receive(:enabled?).
        with(:alaveteli_pro).and_return(true)
      using_session(login(FactoryBot.create(:pro_user))) do
        visit help_about_path
        add_plain_link_to(frontpage_path)
        expect_turbo_visit { find_by_id('plain-link').click }
        expect(page).to have_current_path(alaveteli_pro_dashboard_path)

        add_plain_link_to(alaveteli_pro_info_requests_path)
        expect_turbo_visit { find_by_id('plain-link').click }
        expect(page).to have_current_path(alaveteli_pro_info_requests_path)

        go_back_with_turbo
        expect(page).to have_current_path(alaveteli_pro_dashboard_path)

        add_plain_link_to(new_alaveteli_pro_info_request_path)
        expect_left_to_browser { find_by_id('plain-link').click }
      end
    end

    # Turbo keeps no copy of a signed-in page, so only a full load lets the
    # browser keep the words on Back.
    it 'keeps what was typed in a followup after a link and Back' do
      owner = FactoryBot.create(:user)
      info_request = FactoryBot.create(:info_request, user: owner)
      words = 'Please could you send the appendix too.'
      using_session(login(owner)) do
        visit new_request_followup_path(info_request.url_title)
        find_by_id('outgoing_message_letter').set(words)
        expect_full_load do
          find("#footer a[href='#{help_contact_path}']").click
        end
        page.go_back
        expect(page).to have_field('outgoing_message_letter',
                                   with: /appendix too/)
      end
    end

    it 'signs out by a full page load' do
      using_session(login(FactoryBot.create(:user))) do
        visit help_about_path
        link = find('a[href^="/profile/sign_out"]', visible: :all)
        expect(link['data-turbo']).to eq('false')
      end
    end
  end

  describe 'a request page’s own forms' do
    include_context 'with incoming attention off'

    let(:owner) { FactoryBot.create(:pro_user) }
    let(:info_request) { FactoryBot.create(:info_request, user: owner) }

    before do
      allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
      allow(AlaveteliFeatures.backend).to receive(:enabled?).
        with(:alaveteli_pro).and_return(true)
      AttachmentFixtures.deliver(info_request,
                                 [['routes.csv', 'text/csv', "route\n1\n"]],
                                 text: "Dear requester,\n\nHere it is.\n")
    end

    it 'refreshes the page in place after an answer, landing on it' do
      using_session(login(owner)) do
        visit show_request_path(info_request.url_title)
        expect(page).to have_css('.receipt__ask')
        page.execute_script(<<~JS)
          window.turboSpecMarker = true;
          window.turboSpecRenders = [];
          document.addEventListener('turbo:render', (event) => {
            window.turboSpecRenders.push(event.detail.renderMethod);
          });
          // Counts the feed controller's connects from here on.
          window.turboSpecConnects = 0;
          const feed = document.querySelector('[data-controller~="feed-reveal"]');
          const controller = feed &&
            Stimulus.getControllerForElementAndIdentifier(feed, 'feed-reveal');
          if (controller) {
            const connect = controller.connect.bind(controller);
            controller.connect = () => { window.turboSpecConnects += 1; connect(); };
          }
        JS

        first('.receipt__chip').click
        expect(page).to have_css('#receipt-answer')
        expect(page.evaluate_script('window.turboSpecMarker')).to be(true)
        expect(page.evaluate_script('window.turboSpecRenders')).to eq(['morph'])
        expect(eventually { active_element == 'receipt-answer' }).to be(true)
        expect(page.evaluate_script('location.hash')).to eq('')

        account = find('#logged_in_bar [data-account-menu-target="link"]')
        expect(account['role']).to eq('button')
        if page.has_css?('[data-controller~="feed-reveal"]', wait: 0)
          restarted = eventually do
            page.evaluate_script('window.turboSpecConnects') > 0
          end
          expect(restarted).to be(true)
        end
      end
    end
  end

  describe 'landing after a request page’s own form' do
    include_context 'with incoming attention off'

    let(:owner) { FactoryBot.create(:pro_user) }
    let(:info_request) { FactoryBot.create(:info_request, user: owner) }

    before do
      last_event_id = info_request.info_request_events.maximum(:id)
      Deadlines::Closure.close!(info_request, user: owner,
                                              final_state: 'successful',
                                              last_event_id: last_event_id)
    end

    it 'opens the closed panel it lands on' do
      using_session(login(owner)) do
        visit show_request_path(info_request.url_title)
        expect(page).to have_css('details.feed__dates', visible: :all)
        expect(page).to have_no_css('details.feed__dates[open]', visible: :all)
        page.execute_script(<<~JS)
          window.turboSpecRenders = [];
          document.addEventListener('turbo:render', (event) => {
            window.turboSpecRenders.push(event.detail.renderMethod);
          });
        JS

        click_button 'Reopen'
        expect(eventually { active_element == 'deadlines' }).to be(true)
        expect(page.evaluate_script('window.turboSpecRenders')).to eq(['morph'])
        expect(page).to have_css('details.feed__dates[open] #deadlines')
      end
    end
  end

  describe 'an attachment’s waiting page' do
    let(:admin) { FactoryBot.create(:admin_user) }
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:attachment) do
      FactoryBot.create(
        :incoming_message, info_request: info_request,
                           foi_attachments_factories: [[:pdf_attachment]]
      ).
        foi_attachments.first.tap { |a| a.update_columns(masked_at: nil) }
    end

    def wait_path
      referer = Rails.application.message_verifier('AttachmentsController').
                generate(show_request_path(info_request.url_title))
      wait_for_attachment_mask_path(id: attachment.to_signed_global_id,
                                    referer: referer)
    end

    before do
      allow_any_instance_of(FoiAttachment).to receive(:mask_later)
    end

    it 'aborts on each disconnect and ignores late replies after reconnect or departure' do
      using_session(login(admin)) do
        visit wait_path
        hold_waiting_fetches(page.current_url)
        3.times do |cycle|
          expect(eventually(wait: 5) { waiting_fetch_count == cycle + 1 }).
            to be(true)
          disconnect_waiting_controller('wait-reload')
          aborted = page.evaluate_script(
            "window.waitingFetches[#{cycle}].signal.aborted"
          )
          expect(aborted).to be(true)
          reconnect_waiting_controller('wait-reload')
          page.execute_script(
            'window.waitingFetches[arguments[0]].resolve({ status: 200 })',
            cycle
          )
        end
        expect(eventually(wait: 5) { waiting_fetch_count == 4 }).to be(true)
        sleep 2.2
        expect(waiting_fetch_count).to eq(4)
        add_plain_link_to(help_about_path)
        expect_turbo_visit { find_by_id('plain-link').click }
        page.execute_script('window.waitingFetches[3].resolve({ status: 302 })')
        sleep 2.2
        expect(page).to have_current_path(help_about_path)
        expect(waiting_fetch_count).to eq(4)
      end
    end

    it 'loads the done page in full once the attachment is ready' do
      using_session(login(admin)) do
        visit wait_path
        expect(page).to have_css('h1', text: 'Attachment processing')
        page.execute_script('window.turboSpecMarker = true')

        attachment.update_columns(masked_at: 1.minute.ago)
        expect(page).to have_css('h1', text: 'Attachment available',
                                       wait: 10)
        expect(page.evaluate_script('window.turboSpecMarker')).to be_nil
      end
    end

    it 'stops asking once the reader has gone elsewhere' do
      using_session(login(admin)) do
        visit wait_path
        page.execute_script(<<~JS)
          const waiting = window.location.href;
          const fetchFor = window.fetch;
          window.turboSpecAsks = 0;
          window.fetch = (resource, ...rest) => {
            if (String(resource) === waiting) { window.turboSpecAsks += 1 }
            return fetchFor(resource, ...rest);
          };
        JS
        asked = eventually(wait: 5) do
          page.evaluate_script('window.turboSpecAsks') > 0
        end
        expect(asked).to be(true)
        add_plain_link_to(help_about_path)
        expect_turbo_visit { find_by_id('plain-link').click }
        page.execute_script('window.turboSpecAsks = 0')

        attachment.update_columns(masked_at: 1.minute.ago)
        # Longer than the two seconds between asks.
        sleep 3
        expect(page.evaluate_script('window.turboSpecAsks')).to eq(0)
        expect(page).to have_current_path(help_about_path)
        expect(page.evaluate_script('window.turboSpecMarker')).to be(true)
      end
    end
  end

  describe 'a document page' do
    include ActiveJob::TestHelper
    include DisclosuresHelpers
    include_context 'with document OCR off'

    let(:owner) { FactoryBot.create(:user, trusted: true) }
    let(:admin) { FactoryBot.create(:admin_user) }
    let(:info_request) { FactoryBot.create(:info_request, user: owner) }
    let(:document) do
      pages = [AttachmentFixtures.letter_page(secret: 'Pothole repairs'),
               AttachmentFixtures.letter_page(secret: 'Ward costs')]
      document = delivered_document(info_request, 'letter.pdf',
                                    'application/pdf',
                                    AttachmentFixtures.pdf(pages: pages),
                                    by: owner, kind: 'decision_letter')
      publish(document, by: admin)
      document.reload
    end

    it 'downloads in full and jumps between its pages without a visit' do
      visit "/documents/#{document.public_id}"
      all('a.document-download').each do |link|
        expect(link['data-turbo']).to eq('false')
      end

      page.execute_script(<<~JS)
        window.turboSpecVisits = 0;
        document.addEventListener('turbo:visit', () => { window.turboSpecVisits += 1 });
      JS
      within('.document-thumbs') { click_link(href: '#page-2') }
      expect(page).to have_current_path(/#page-2\z/, url: true)
      expect(page.evaluate_script('window.turboSpecVisits')).to eq(0)
    end
  end
end
