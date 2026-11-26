require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'A request page', js: true do
  let(:info_request) { FactoryBot.create(:info_request) }

  let!(:incoming) do
    FactoryBot.create(
      :incoming_message,
      info_request: info_request,
      foi_attachments_factories: Array.new(5) { [:pdf_attachment] }
    ).tap do |message|
      info_request.log_event('response', incoming_message_id: message.id)
    end
  end

  let(:outgoing) { info_request.outgoing_messages.first }

  # The private archive shows a request's classic page to an admin.
  let(:admin) { FactoryBot.create(:admin_user) }

  # In the spec's own session: an around hook would sign in before
  # driven_by picks the browser.
  before do
    admin.update!(otp_secret: User.generate_otp_secret,
                  otp_required_for_login: true)
    visit signin_path
    within '#signin_form' do
      fill_in 'user_signin_email', with: admin.email
      fill_in 'user_signin_password', with: 'jonespassword'
      fill_in 'user_signin_otp_attempt', with: admin.current_otp
      click_button(name: 'commit')
    end
    expect(page).to have_no_css('#signin_form')
  end

  def message(record)
    find(".#{record.class.name.underscore.split('_').first}.correspondence")
  end

  # Simulates a Turbo morph refresh (see helpers/morph_refresh).
  def refresh_in_place
    page.execute_script(<<~JS)
      window.specRenders = [];
      document.addEventListener('turbo:render', (event) => {
        window.specRenders.push(event.detail.renderMethod);
      });
      Turbo.visit(location.href, { action: 'replace' });
    JS
    morphed = eventually do
      page.evaluate_script('window.specRenders') == ['morph']
    end
    expect(morphed).to be(true)
  end

  it 'marks how long passed between messages' do
    visit show_request_path(info_request.url_title)
    expect(page).to have_css('.thread-gap')
  end

  it 'folds a message by its author and opens it again' do
    visit show_request_path(info_request.url_title)
    trigger = message(outgoing).find('.correspondence__header__author')
    expect(trigger['aria-expanded']).to eq('true')

    trigger.click
    expect(message(outgoing)[:class]).to include('collapsed')
    expect(trigger['aria-expanded']).to eq('false')

    trigger.send_keys(:enter)
    expect(message(outgoing)[:class]).not_to include('collapsed')
  end

  it 'opens the Actions menu, collapses everything from it, and shuts it' do
    visit show_request_path(info_request.url_title)
    menu = first('.after-actions__action-menu')
    button = menu.find('.action-menu__button')
    expect(menu).to have_no_css('.action-menu__menu', visible: :visible)

    button.click
    expect(button['aria-expanded']).to eq('true')
    expect(menu).to have_css('.action-menu__menu', visible: :visible)

    menu.click_link 'Collapse all correspondence'
    expect(page).to have_css('.correspondence.collapsed', count: 2)
    expect(menu).to have_link('Expand all correspondence')

    menu.click_link 'Expand all correspondence'
    expect(page).to have_no_css('.correspondence.collapsed')

    find('body').send_keys(:escape)
    expect(menu).to have_no_css('.action-menu__menu', visible: :visible)
    expect(button['aria-expanded']).to eq('false')

    button.click
    find('#content h1').click
    expect(menu).to have_no_css('.action-menu__menu', visible: :visible)
  end

  it 'shows three attachments, then the rest on asking' do
    visit show_request_path(info_request.url_title)
    attachments = message(incoming).find('.attachments')
    expect(attachments).to have_css('.attachment', count: 3, visible: :visible)

    attachments.click_link 'Show all attachments'
    expect(attachments).to have_css('.attachment', count: 5, visible: :visible)

    attachments.click_link 'Show fewer attachments'
    expect(attachments).to have_css('.attachment', count: 3, visible: :visible)
  end

  it 'lists the attachments in the sidebar' do
    visit show_request_path(info_request.url_title)
    expect(page).to have_css('#right_column .sidebar__documents li',
                             count: 5, visible: :all)
  end

  it 'marks the gaps and lists the attachments again after a refresh in place' do
    visit show_request_path(info_request.url_title)
    expect(page).to have_css('.thread-gap')
    gaps = all('.thread-gap').size

    refresh_in_place
    expect(page).to have_css('.thread-gap', count: gaps)
    expect(page).to have_css('#right_column .sidebar__documents',
                             count: 1, visible: :all)
    expect(page).to have_css('#right_column .sidebar__documents li',
                             count: 5, visible: :all)
  end

  it 'links each message’s date to the message' do
    visit show_request_path(info_request.url_title)

    [incoming, outgoing].each do |record|
      letter = message(record)
      letter.find('.correspondence__header__date').click
      expect(page).to have_current_path(/##{letter[:id]}\z/, url: true)
    end
  end

  it 'shows the mail server’s log for a sent message in place, and hides it' do
    visit show_request_path(info_request.url_title)
    status = message(outgoing).find('.toggle-delivery-log')
    status.click
    expect(message(outgoing)).to have_css('.correspondence_delivery')
    expect(status['aria-expanded']).to eq('true')
    expect(page).to have_current_path(show_request_path(info_request.url_title))

    status.click
    expect(message(outgoing)).to have_no_css('.correspondence_delivery')
  end

  it 'shows the mail server’s log at the first click after a refresh in place' do
    visit show_request_path(info_request.url_title)
    message(outgoing).find('.toggle-delivery-log').click
    expect(message(outgoing)).to have_css('.correspondence_delivery')

    refresh_in_place
    expect(message(outgoing)).to have_no_css('.correspondence_delivery')
    status = message(outgoing).find('.toggle-delivery-log')
    status.click
    expect(message(outgoing)).to have_css('.correspondence_delivery')
    expect(status['aria-expanded']).to eq('true')
  end
end
