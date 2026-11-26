require 'spec_helper'

# A requester's file that the publish step's safety checks refuse goes to the
# admin review queue, with the reason, instead of stopping the requester.
RSpec.describe 'A refused requester publication goes to the review queue' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include SettingsHelpers
  include_context 'with document OCR off'

  let(:owner) do
    FactoryBot.create(:user, name: 'Rowan Requester',
                             email: 'rowan.requester@example.org')
  end
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:login_url) do
    "https://#{AlaveteliConfiguration.domain}/c/secret-token-123"
  end
  let(:docx_type) do
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  end

  def deliver(files)
    message = AttachmentFixtures.deliver(info_request, files)
    documents = files.map do |name, _type, _bytes|
      attachment = file_in(message, name)
      read_by_analyzer(attachment)
      Disclosures::Creation.new(user: owner, attachment: attachment,
                                kind: 'released_records').create!
    end
    [message, *documents]
  end

  def reply_args(message)
    { url_title: info_request.url_title, message_id: message.id }
  end

  def queued(document)
    Disclosures::ReviewQueue.new(Ability.new(admin)).drafts.
      find { |draft| draft.document == document }
  end

  it 'publishes the clean file and queues the refused one with its reason' do
    message, clean, refused = deliver(
      [['clean.docx', docx_type,
        AttachmentFixtures.docx(paragraphs: ['The road contract summary.'])],
       ['login.docx', docx_type,
        AttachmentFixtures.docx(paragraphs: ["Sign in here: #{login_url}"])]]
    )

    sign_in owner
    post publish_reply_check_path(**reply_args(message)),
         params: { documents: [clean.public_id, refused.public_id] }

    expect(response).
      to redirect_to(publish_reply_published_path(**reply_args(message)))
    expect(clean.reload.state).to eq('published')
    expect(refused.reload.state).to eq('draft')
    expect(refused.foi_attachment.reload.prominence).to eq('requester_only')
    expect(refused.pages.count).to eq(0)
    expect(Disclosures::ReviewSubmission.pending?(refused)).to be(true)

    follow_redirect!
    expect(response.body).to include('Waiting for admin review')

    expect(queued(refused).why).to match(/sign-in link/)
    expect(queued(clean)).to be_nil

    requester = Ability.new(owner)
    expect(requester.can?(:redact_document, refused.reload)).to be(false)
    expect(requester.can?(:mark_publication_unwanted, refused)).to be(true)
  end

  it 'shows the reason on the admin’s page, where they can publish it' do
    message, refused = deliver(
      [['login.docx', docx_type,
        AttachmentFixtures.docx(paragraphs: ["Sign in here: #{login_url}"])]]
    )
    sign_in owner
    post publish_reply_check_path(**reply_args(message)),
         params: { documents: [refused.public_id] }

    sign_in admin
    document_request(:get, disclosure_manage_document_path(refused))
    expect(response.body).to include('sign-in link')

    document_request(:post, disclosure_publish_document_path(refused))
    expect(refused.reload.state).to eq('published')
    expect(Disclosures::ReviewSubmission.pending?(refused)).to be(false)
  end

  it 'queues the file when hiding the name leaves a refusal' do
    pdf = DocumentFixtures.text_pdf(
      title: 'Letter',
      paragraphs: ['Dear Rowan Requester, this page has more than forty ' \
                   'characters of body text, so it is read directly.']
    )
    message, document = deliver([['letter.pdf', 'application/pdf', pdf]])

    with_setting(Disclosures, :ocr, true) do
      allow(PDFRedactor::Survey).to receive(:pages).and_return(
        [{ 'number' => 1, 'visible' => 100, 'unmapped' => 0,
           'picture_share' => 0.25 }]
      )
      allow(Disclosures::Ocr).to receive(:pdf_page).
        and_return('Screenshot showing private.person@example.org')
      sign_in owner
      post publish_reply_hide_name_path(**reply_args(message), id: document)
    end

    expect(response).
      to redirect_to(publish_reply_published_path(**reply_args(message)))
    expect(flash[:notice]).to include('An admin will check it')
    expect(document.reload.state).to eq('draft')
    expect(Disclosures::ReviewSubmission.pending?(document)).to be(true)
    expect(queued(document).why).to match(/personal details/)
  end

  it 'queues a requester’s edit that the checks refuse when review is off' do
    pdf = DocumentFixtures.text_pdf(title: 'Briefing',
                                    paragraphs: ['Keep this heading.',
                                                 'ManualBoxTarget'])
    message, document = deliver([['briefing.pdf', 'application/pdf', pdf]])

    with_setting(Disclosures, :review_requester_redactions, false) do
      with_setting(Disclosures, :ocr, true) do
        allow(Disclosures::Ocr).to receive(:pdf_page).
          and_return('Contact citizen@example.org for details.')
        sign_in owner
        post publish_reply_redact_path(**reply_args(message), id: document),
             params: { kind: 'pdf_redaction',
                       boxes: { '1' => [[0.0, 0.8, 0.4, 0.9]] }.to_json }
      end
    end

    expect(response).
      to redirect_to(publish_reply_check_path(**reply_args(message)))
    expect(flash[:notice]).to include('An admin will check this file')
    expect(document.foi_attachment.reload.prominence).
      to eq('requester_only')
    expect(document.reload.state).to eq('draft')
    expect(Disclosures::ReviewSubmission.pending?(document)).to be(true)
    expect(queued(document).why).to match(/personal details/)
  end
end
