require 'spec_helper'
require 'zip'

RSpec.describe 'File downloads', type: :request do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }

  let(:on_every_response) do
    { 'cache-control' => 'private, no-store',
      'content-language' => 'en',
      'referrer-policy' => 'strict-origin-when-cross-origin',
      'x-content-type-options' => 'nosniff',
      'x-frame-options' => 'sameorigin',
      'x-permitted-cross-domain-policies' => 'none' }
  end

  let(:session_cookie) { a_string_starting_with('_nedervetil_session=') }
  let(:weak_etag) { a_string_matching(/\AW\/"\h{32}"\z/) }
  let(:page_policy_with_nonce) do
    a_string_matching(/\Adefault-src 'self' https:; .*'nonce-[^']+'/)
  end

  def attachment_named(name)
    "attachment; filename=\"#{name}\"; filename*=UTF-8''#{name}"
  end

  def entries(zip_bytes)
    names = nil
    Zip::File.open_buffer(StringIO.new(zip_bytes)) do |zip|
      names = zip.entries.map(&:name)
    end
    names
  end

  describe 'a file in a reply, sent from memory' do
    let(:info_request) do
      FactoryBot.create(:info_request_with_pdf_attachment, user: owner)
    end
    let(:attachment) do
      info_request.incoming_messages.first.foi_attachments.
        find_by!(filename: 'interesting.pdf')
    end
    let(:path) do
      get_attachment_path(info_request.url_title,
                          incoming_message_id: attachment.incoming_message_id,
                          part: attachment.url_part_number,
                          file_name: attachment.display_filename)
    end
    let(:headers) do
      on_every_response.merge(
        'content-disposition' => attachment_named('interesting.pdf'),
        'content-security-policy' =>
          "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; " \
          'sandbox',
        'content-transfer-encoding' => 'binary',
        'etag' => weak_etag,
        'set-cookie' => session_cookie,
        'vary' => 'Cookie, Accept, X-Requested-With'
      )
    end

    before do
      sign_in(owner)
      # The first request masks the file in a job; the next one sends it.
      get path
      perform_enqueued_jobs
    end

    it 'arrives whole, with its length, type and an ETag' do
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(attachment.reload.body.b)
      expect(sent_headers).to match(
        headers.merge('content-type' => 'application/pdf',
                      'content-length' => response.body.bytesize.to_s)
      )
    end

    it 'answers HEAD with the same headers but the length, and no body' do
      head path

      expect(response).to have_http_status(:ok)
      expect(response.body).to be_empty
      expect(sent_headers).
        to match(headers.merge('content-type' => 'application/pdf'))
    end

    it 'answers Not Modified, with no body, to a browser holding the ETag' do
      get path
      get path, headers: { 'If-None-Match' => response.headers['etag'] }

      expect(response).to have_http_status(:not_modified)
      expect(response.body).to be_empty
      expect(sent_headers).to match(headers)
    end
  end

  describe 'a published document, sent from disk' do
    it 'arrives whole, with its length and type, and no cookie' do
      info_request = FactoryBot.create(:info_request, user: owner,
                                                      title: 'Gritting routes')
      letter = AttachmentFixtures.pdf(
        pages: [AttachmentFixtures.letter_page(secret: 'Salt by ward')]
      )
      document = delivered_document(info_request, 'response.pdf',
                                    'application/pdf', letter)
      publish(document, by: admin)
      reset!

      get "/documents/#{document.public_id}/download"

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(document.bytes)
      expect(sent_headers).to match(
        on_every_response.merge(
          'content-disposition' =>
            a_string_matching(/\Aattachment; filename="released-records-/),
          'content-length' => response.body.bytesize.to_s,
          'content-security-policy' => "default-src 'none'; sandbox",
          'content-transfer-encoding' => 'binary',
          'content-type' => 'application/pdf',
          'vary' => 'Cookie, Accept, X-Requested-With'
        )
      )
    end
  end

  describe 'a whole request as a ZIP, sent from disk' do
    after { FileUtils.rm_rf(RegulatorPack.storage_dir) }

    it 'arrives as a ZIP of the correspondence and its files' do
      info_request =
        FactoryBot.create(:info_request_with_pdf_attachment, user: owner)
      token = RegulatorPack.new(info_request, user: owner).build!
      sign_in(owner)

      get download_regulator_pack_path(token: token)

      expect(response).to have_http_status(:ok)
      expect(entries(response.body)).
        to eq(%w[correspondence.txt 1_2_interesting.pdf])
      expect(sent_headers).to match(
        on_every_response.merge(
          'content-disposition' =>
            attachment_named("#{info_request.url_title}.zip"),
          'content-length' => response.body.bytesize.to_s,
          'content-security-policy' => page_policy_with_nonce,
          'content-transfer-encoding' => 'binary',
          'content-type' => 'application/zip',
          'set-cookie' => session_cookie,
          'vary' => 'Cookie'
        )
      )
    end
  end

  describe 'a batch of requests as a ZIP, written as it is built' do
    it 'arrives as a ZIP, marked for nginx to pass on without buffering' do
      batch = FactoryBot.create(:info_request_batch, user: owner)
      sign_in(owner)

      get alaveteli_pro_info_request_batch_batch_download_path(batch,
                                                               format: :zip)

      expect(response).to have_http_status(:ok)
      expect(entries(response.body)).
        to match([a_string_matching(/\Abatch-.*-dashboard-.*\.csv\z/)])
      expect(sent_headers).to match(
        on_every_response.merge(
          'content-disposition' =>
            a_string_matching(/\Aattachment; filename="batch-.*\.zip"/),
          'content-length' => response.body.bytesize.to_s,
          'content-security-policy' => page_policy_with_nonce,
          'content-transfer-encoding' => 'binary',
          'content-type' => 'application/zip',
          'last-modified' => a_string_matching(/ GMT\z/),
          'set-cookie' => session_cookie,
          'vary' => 'Cookie',
          'x-accel-buffering' => 'no'
        )
      )
    end
  end
end
