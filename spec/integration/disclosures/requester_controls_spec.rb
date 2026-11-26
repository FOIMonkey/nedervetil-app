require 'spec_helper'

RSpec.describe 'Requester Document controls' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:other) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:message) do
    AttachmentFixtures.deliver(info_request,
                               [['records.txt', 'text/plain',
                                 "Dear Rowan Requester,\nRecords by ward.\n"]])
  end
  let(:attachment) do
    message.get_attachments_for_display.
      find { |part| part.filename == 'records.txt' }
  end

  around do |example|
    with_setting(Disclosures, :requester_editing, nil) { example.run }
  end

  before { requester_editing(false) }

  def requester_editing(value)
    allow(AlaveteliConfiguration).
      to receive(:disclosures_requester_editing).and_return(value)
  end

  def draft
    Disclosures::Creation.new(user: admin,
                              attachment: attachment,
                              kind: 'released_records').create!
  end

  def path(document, suffix = '')
    "/documents/#{document.public_id}#{suffix}"
  end

  it 'defaults on, and fails closed for anything but true' do
    allow(AlaveteliConfiguration).
      to receive(:disclosures_requester_editing).and_call_original
    expect(Disclosures.requester_editing?).to be true
    [false, nil, '', 'on', 'true', 'invalid'].each do |choice|
      requester_editing(choice)
      expect(Disclosures.requester_editing?).to be false
    end
    requester_editing(true)
    expect(Disclosures.requester_editing?).to be true
  end

  it 'reviews requester redactions whatever the review setting says' do
    with_setting(Disclosures, :review_requester_redactions, false) do
      expect(Disclosures.review_requester_redactions?).to be true
      requester_editing(true)
      expect(Disclosures.review_requester_redactions?).to be false
    end
  end

  it 'keeps drafts for seven days, and for the set hours with editing on' do
    with_setting(AttachmentManagement, :draft_retention, nil) do
      expect(AttachmentManagement.draft_retention).to eq(7.days)
      requester_editing(true)
      expect(AttachmentManagement.draft_retention).to eq(4.hours)
    end
  end

  it 'denies forged requester creation and keeps admin creation available' do
    attachment
    sign_in(owner)
    expect {
      document_request :post, '/documents',
           params: { attachment_id: attachment.id, kind: 'released_records' }
    }.not_to change(Disclosures::Document, :count)
    expect(response).to have_http_status(:not_found)
    sign_in(admin)
    expect {
      document_request :post, '/documents',
           params: { attachment_id: attachment.id, kind: 'released_records' }
    }.to change(Disclosures::Document, :count).by(1)
    expect(response).to have_http_status(:redirect)
  end

  it 'denies every requester file-changing action while preserving read access' do
    document = draft
    ability = Ability.new(owner)
    expect(ability.can?(:manage_document, document)).to be true
    %i[edit_document redact_document delete_document
       change_document_file publish_document].each do |action|
      expect(ability.can?(action, document)).to be false
    end
    sign_in(owner)
    document_request :get, path(document, '/manage')
    expect(response).to have_http_status(:ok)
    expect(response.body).
      not_to include('Edit details', 'Redact this file', 'Delete this draft')
    document_request :patch, path(document),
                     params: { document: { title: 'Forged title' } }
    expect(response).to have_http_status(:not_found)
    expect(document.reload.title).not_to eq('Forged title')
    expect { delete path(document) }.
      not_to change(Disclosures::Document, :count)
    expect(response).to have_http_status(:not_found)
  end

  it 'rechecks creation permission in the service if the flag changes after the form check' do
    requester_editing(true)
    expect(Ability.new(owner).can?(:create_document, attachment)).to be true
    requester_editing(false)
    expect do
      Disclosures::Creation.new(user: owner,
                                attachment: attachment,
                                kind: 'released_records').create!
    end.to raise_error(Disclosures::Error::Refused, /can’t make/)
    expect(Disclosures::Document.where(foi_attachment_id: attachment.id)).
      to be_empty
  end

  it 'is independent of the thread attachment switch in both directions' do
    document = draft
    allow(AttachmentManagement).
      to receive(:requester_access).and_return('redact')
    expect(Ability.new(owner).can?(:manage_attachment, attachment)).to be true
    expect(Ability.new(owner).can?(:redact_document, document)).to be false
    requester_editing(true)
    allow(AttachmentManagement).to receive(:requester_access).and_return('none')
    expect(Ability.new(owner).can?(:manage_attachment, attachment)).to be false
    expect(Ability.new(owner).can?(:redact_document, document)).to be true
    expect(Ability.new(owner).can?(:create_document, attachment)).to be true
    expect(Ability.new(owner).can?(:publish_document, document)).to be false
  end

  def send_for_review
    document_request :post, '/documents/review',
         params: { attachment_id: attachment.id, kind: 'released_records' }
  end

  def queued
    sign_in(owner)
    send_for_review
    expect(response).to have_http_status(:redirect)
    Disclosures::Document.find_by!(foi_attachment_id: attachment.id)
  end

  it 'offers admin review rather than Make and lists it in the admin review queue' do
    attachment
    suggest_documents
    sign_in(owner)
    document_request :get, "/request/#{info_request.url_title}"
    expect(response.body).to include('for admin review')
    expect(response.body).
      not_to include('Make released records', 'Make decision letter')
    expect { send_for_review }.to change(Disclosures::Document, :count).by(1)
    document = Disclosures::Document.find_by!(foi_attachment_id: attachment.id)
    expect(document).to be_draft
    expect(document.events.pluck(:action)).to eq(['review_requested'])
    expect { send_for_review }.not_to change(Disclosures::Document, :count)
    expect(document.events.count).to eq(1)
    expect(response).to redirect_to(path(document, '/manage'))

    sign_in(admin)
    document_request :get, '/documents/review'
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(document.title)
  end

  it 'denies visitor, unrelated, banned and closed accounts at the queue boundary' do
    attachment
    [nil, other, owner].each do |user|
      user ? sign_in(user) : reset!
      owner.update!(ban_text: 'Synthetic ban') if user == owner
      expect { send_for_review }.not_to change(Disclosures::Document, :count)
      expect(response).to have_http_status(:not_found)
    end
    owner.update!(ban_text: '')
    sign_in(owner)
    owner.close!
    expect { send_for_review }.not_to change(Disclosures::Document, :count)
    expect(response).to have_http_status(:not_found)
  end

  it 'keeps the private admin queue inaccessible to requesters, unrelated users and visitors' do
    document = queued
    [nil, owner, other].each do |user|
      user ? sign_in(user) : reset!
      document_request :get, '/documents/review'
      expect(response.body).not_to include(document.title)
      expect(response.body).not_to include('These drafts are private')
      expect(response).to have_http_status(:not_found) if user
    end
    reset!
    document_request :get, path(document)
    expect(response).to have_http_status(:not_found)
  end

  it 'keeps the existing creation limits on admin-review requests' do
    attachment
    allow(Disclosures).to receive(:daily_documents).and_return(0)
    sign_in(owner)
    expect { send_for_review }.not_to change(Disclosures::Document, :count)
    expect(flash[:error]).to include('Try again tomorrow')
  end

  it 'rejects a forged queue POST without CSRF before any document is made' do
    attachment
    sign_in(owner)
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(true)
    ActionController::Base.allow_forgery_protection = true
    expect do
      send_for_review
      expect(response).to have_http_status(422)
    rescue ActionController::InvalidAuthenticityToken
      # Core raises instead of rendering the 422 in some test configurations.
    end.not_to change(Disclosures::Document, :count)
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  it 'leaves the normal Make workflow intact when requester editing is on' do
    requester_editing(true)
    attachment
    sign_in(owner)
    expect { send_for_review }.not_to change(Disclosures::Document, :count)
    expect(response).to have_http_status(:not_found)
    expect {
      document_request :post, '/documents',
           params: { attachment_id: attachment.id, kind: 'released_records' }
    }.to change(Disclosures::Document, :count).by(1)
  end
end
