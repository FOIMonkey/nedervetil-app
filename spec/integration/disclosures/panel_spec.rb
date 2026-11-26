require 'spec_helper'
require 'zip'

RSpec.describe 'Disclosures request panel' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:other) { FactoryBot.create(:user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Gritting routes 2024')
  end
  let!(:message) do
    AttachmentFixtures.deliver(
      info_request,
      [['runs.txt', 'text/plain', "Gritting runs by ward\nNorth: 12\n"]]
    )
  end

  def panel
    Nokogiri::HTML(response.body).at_css('[data-documents-panel]')
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def share_link
    page.css('a').find { |link| link.text == 'Share documents' }
  end

  def request_page
    get "/request/#{info_request.url_title}"
    expect(response).to have_http_status(:ok)
  end

  it 'is shown to an admin, and the requester shares from the reply instead' do
    sign_in(owner)
    request_page
    expect(panel).to be_nil
    expect(share_link['href']).
      to eq("/request/#{info_request.url_title}/publish/#{message.id}")

    sign_in(admin)
    request_page
    expect(panel).to be_present
    expect(panel.at_css('#documents-panel-title').text).to eq('Documents')
  end

  it 'is not shown to another user or a visitor' do
    reset!
    get "/request/#{info_request.url_title}"
    expect(response).to have_http_status(:not_found)
    expect(panel).to be_nil

    sign_in(other)
    get "/request/#{info_request.url_title}"
    expect(response).to have_http_status(:not_found)
    expect(panel).to be_nil
  end

  it 'is not shown on the holding pen, and queues nothing for its replies' do
    holding_pen = InfoRequest.holding_pen_request
    held = AttachmentFixtures.deliver(
      holding_pen, [['runs.txt', 'text/plain', "Misdelivered runs\n"]]
    )
    clear_enqueued_jobs
    expect(Ability.new(admin).can?(:see_document_panel, holding_pen)).
      to be false

    sign_in(admin)
    get "/request/#{holding_pen.url_title}"
    expect(response).to have_http_status(:ok)
    expect(panel).to be_nil
    expect(Disclosures::SuggestJob).not_to have_been_enqueued.with(held.id)
  end

  it 'is left out of the text of the request’s ZIP download' do
    token = RegulatorPack.new(info_request, user: owner).build!
    sign_in(owner)
    get download_regulator_pack_path(token: token)
    expect(response).to have_http_status(:ok)
    # open_buffer's block form returns the buffer, not the block's value.
    text = Zip::File.open_buffer(StringIO.new(response.body)).
      find_entry('correspondence.txt').get_input_stream.read
    expect(text).to include('Gritting routes 2024')
    expect(text).not_to include('only you and the site’s admins can see it',
                                'documents-panel',
                                'Make released records')
  ensure
    FileUtils.rm_rf(RegulatorPack.storage_dir)
  end

  it 'looks up the documents made from a request’s files once for the page, not once per file' do
    AttachmentFixtures.deliver(
      info_request,
      Array.new(4) do |i|
        ["route-#{i}.txt", 'text/plain', "Gritting route #{i}\n"]
      end
    )
    suggest_documents
    attachment = message.get_attachments_for_display.first
    Disclosures::Creation.new(user: owner,
                              attachment: attachment,
                              kind: 'released_records').create!
    statements = []
    count = ->(*, payload) do
      if payload[:sql].include?('"disclosure_documents"."foi_attachment_id"')
        statements << payload[:sql]
      end
    end
    sign_in(admin)
    ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
      request_page
    end

    expect(panel).to be_present
    expect(response.body).to include('Document: ')
    # One read, for the panel's files: the files shown in the thread use it.
    expect(statements.size).to eq(1), -> { statements.join("\n") }
    expect(statements).
      to all(include('"disclosure_documents"."foi_attachment_id" IN ('))
  end

  it 'shows a reply with no suggestions yet as pending and queues the job, working nothing out itself' do
    Disclosures::Suggestion.where(incoming_message_id: message.id).delete_all
    clear_enqueued_jobs
    sign_in(owner)
    request_page
    expect(page.css('.documents-panel__file')).to be_empty
    expect(share_link).to be_present
    expect(Disclosures::SuggestJob).to have_been_enqueued.with(message.id)
    expect(Disclosures::Suggestion.where(incoming_message_id: message.id)).
      to be_empty
  end

  it 'offers publishing from the reply, then lists the document it made' do
    suggest_documents
    attachment = message.get_attachments_for_display.
      find { |part| part.filename == 'runs.txt' }
    sign_in(owner)
    request_page
    expect(share_link['href']).
      to eq("/request/#{info_request.url_title}/publish/#{message.id}")

    post '/documents',
         params: { attachment_id: attachment.id, kind: 'released_records' }
    document = Disclosures::Document.find_by!(foi_attachment_id: attachment.id)
    expect(response).to redirect_to("/documents/#{document.public_id}/manage")
    expect(document).to have_attributes(state: 'draft',
                                        created_by: owner,
                                        kind: 'released_records')

    request_page
    expect(page.at_css('.attachment__document').text).to include(document.title)
    expect(page.at_css('.attachment__document a')['href']).to be_present

    sign_in(other)
    post '/documents',
         params: { attachment_id: attachment.id, kind: 'released_records' }
    expect(response).to have_http_status(:not_found)
  end
end
