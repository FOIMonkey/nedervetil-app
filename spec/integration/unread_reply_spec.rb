require 'spec_helper'

RSpec.describe 'A reply whose mail can’t be read yet' do
  include MailReadHelpers
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:page) { "/request/#{info_request.url_title}" }
  let(:note) { 'We were not able to process this message.' }
  let!(:message) do
    receive_incoming_mail('incoming-request-two-same-name.eml',
                          to: info_request.incoming_email)
    info_request.incoming_messages.last
  end

  def stored
    IncomingMessage.where(id: message.id).
      pick(:last_parsed, :cached_main_body_text_folded)
  end

  before do
    refuse_mail_reads
    allow(Rails.logger).to receive(:warn)
  end

  it 'is shown on the request page with the note and no attachments, and ' \
     'nothing is stored' do
    sign_in(owner)
    get page

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("incoming-#{message.id}")
    expect(response.body).to include(note)
    expect(response.body).not_to include('hello world.txt')
    expect(stored).to eq([nil, nil])
    expect(message.foi_attachments.reload).to be_empty
  end

  it 'is shown with its text and attachments once the mail can be read' do
    sign_in(owner)
    get page
    allow_mail_reads
    get page

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(note)
    expect(response.body).to include('hello world.txt')
    expect(stored.first).to be_present
  end

  it 'does not stop the admin pages for its request and for itself' do
    sign_in(admin)

    get "/admin/requests/#{info_request.id}"
    expect(response).to have_http_status(:ok)

    get "/admin/incoming_messages/#{message.id}/edit"
    expect(response).to have_http_status(:ok)
    expect(stored).to eq([nil, nil])
  end

  describe 'whose email was erased before anything read it' do
    include ActiveJob::TestHelper

    before do
      message.raw_email.erase(editor: admin, reason: 'Asked for')
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
      allow_mail_reads
    end

    it 'is shown on the request page with no text and no attachments' do
      expect(message.raw_email.reload).to be_erased
      sign_in(owner)

      get page

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("incoming-#{message.id}")
      expect(response.body).not_to include(note)
      expect(stored).to eq([nil, ''])
    end

    it 'does not stop the request’s zip being made' do
      skip 'RegulatorPack arrives in B09' unless defined?(RegulatorPack)

      token = RegulatorPack.new(info_request, user: owner).build!
      sign_in(owner)

      get download_regulator_pack_path(token: token)

      expect(response).to have_http_status(:ok)
    ensure
      FileUtils.rm_rf(RegulatorPack.storage_dir) if defined?(RegulatorPack)
    end

    it 'does not stop a batch’s zip being made' do
      batch = FactoryBot.create(:info_request_batch,
                                info_requests: [info_request])
      ability = Object.new.extend(CanCan::Ability)
      ability.can :read, [InfoRequest, IncomingMessage, FoiAttachment]
      allow(InfoRequestBatchMetrics).to receive(:new).
        and_return(double(:metrics, name: 'NAME', to_csv: 'CSV_DATA'))

      zip = InfoRequestBatchZip.new(batch, ability: ability)

      expect(zip.files.map(&:path)).to eq(['NAME'])
    end
  end

  it 'has no attachment to download yet' do
    sign_in(owner)
    get "#{page}/response/#{message.id}/attach/2/hello-world.txt"

    expect(response).to redirect_to("#{page}#incoming-#{message.id}")
  end
end
