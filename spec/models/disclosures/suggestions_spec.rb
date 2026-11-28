require 'spec_helper'

RSpec.describe 'Disclosures suggestions' do
  include ActiveJob::TestHelper
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Fleet vehicles 2025')
  end

  def suggestions_for(message)
    Disclosures::Suggester.new(message).run
    Disclosures::Suggestion.where(incoming_message_id: message.id).to_a
  end

  def by_name(rows)
    rows.to_h { |row| [row.foi_attachment.filename, row.suggestion] }
  end

  it 'sorts a reply’s files into the decision letter, released records, things to set aside and files that stay' do
    letter = DocumentFixtures.decision_letter_pdf(
      requester: 'Rowan Requester',
      authority: 'Synthetic Borough Council',
      ref: 'FOI-2025-0042',
      paragraphs: ['You asked for the number of fleet vehicles. The ' \
                   'information you requested is held and is attached.']
    )
    sheet = DocumentFixtures.xlsx(
      sheets: [{ name: 'Fleet',
                 rows: [%w[Depot Vehicles], ['North', 12], ['South', 9]] }]
    )
    archive = DocumentFixtures.zip(
      'vehicles.csv' => DocumentFixtures.csv([%w[Depot Vehicles], %w[North 12]])
    )
    message = AttachmentFixtures.deliver(
      info_request,
      [
        ['FOI-2025-0042 response.pdf', 'application/pdf', letter],
        ['fleet-vehicles.xlsx',
         'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
         sheet],
        [DocumentFixtures::LEAFLET_FILENAME, 'application/pdf',
         DocumentFixtures.leaflet_pdf(authority: 'Synthetic Borough Council')],
        ['signature.png', 'image/png', DocumentFixtures.signature_png],
        ['records.zip', 'application/zip', archive]
      ]
    )
    rows = suggestions_for(message)

    expect(by_name(rows)).to include(
      'FOI-2025-0042 response.pdf' => 'decision_letter',
      'fleet-vehicles.xlsx' => 'released_records',
      'foi-complaints-procedure.pdf' => 'set_aside',
      'signature.png' => 'none',
      'records.zip' => 'none'
    )
    rules = rows.to_h { |row| [row.foi_attachment.filename, row.rule] }
    expect(rules).to include('FOI-2025-0042 response.pdf' => 'letter_pick',
                             'fleet-vehicles.xlsx' => 'spreadsheet',
                             'foi-complaints-procedure.pdf' => 'leaflet',
                             'signature.png' => 'format',
                             'records.zip' => 'format')
    # Fresh straight away, although reading the files masked them.
    expect(rows).to all(
      satisfy { |row| row.fresh?(FoiAttachment.find(row.foi_attachment_id)) }
    )

    email = rows.find { |row| row.rule.to_s.start_with?('email') }
    expect(email).
      to have_attributes(suggestion: 'set_aside',
                         rule: 'email_with_letter',
                         foi_attachment_id: message.get_main_body_text_part.id)
  end

  # A reply whose mail can't be read yet lists no files. That must not be
  # taken for a reply with none: the job fails, and is tried again.
  it 'raises when the reply’s mail can’t be read, and settles nothing' do
    receive_incoming_mail('incoming-request-two-same-name.eml',
                          to: info_request.incoming_email)
    message = info_request.incoming_messages.last
    allow(MailHandler::Reading).to receive(:of).
      and_raise(MailHandler::ReadRefused, 'the mail cell is down')

    expect { Disclosures::Suggester.new(message).run }.
      to raise_error(MailHandler::ReadRefused)
    expect(Disclosures::Suggestion.where(incoming_message_id: message.id)).
      to be_empty
  end

  it 'gives a file in a format that can’t become a document no suggestion' do
    files = { 'slides.ppt' => 'application/vnd.ms-powerpoint',
              'notes.odt' => 'application/vnd.oasis.opendocument.text',
              'figures.ods' => 'application/vnd.oasis.opendocument.spreadsheet',
              'letter.rtf' => 'application/rtf',
              'photo.jpg' => 'image/jpeg',
              'archive.zip' => 'application/zip' }
    message = AttachmentFixtures.deliver(
      info_request,
      files.map { |name, type| [name, type, "Synthetic #{name}\n" * 20] }
    )
    rows = suggestions_for(message).
      reject { |row| row.rule.to_s.start_with?('email') }
    expect(
      rows.map { |row| [row.foi_attachment.filename, row.suggestion, row.rule] }
    ).to match_array(files.keys.map { |name| [name, 'none', 'format'] })
  end

  it 'suggests valid legacy .xls and .doc attachments' do
    xls_path = Rails.root.join('gems/excel_analyzer/spec/fixtures/data.xls')
    doc_path = Rails.root.join('spec/fixtures/files/lorem.doc')
    message = AttachmentFixtures.deliver(
      info_request,
      [['budget.xls', 'application/vnd.ms-excel', File.binread(xls_path)],
       ['minutes.doc', 'application/vnd.ms-word', File.binread(doc_path)]]
    )
    rows = suggestions_for(message).index_by do |row|
      row.foi_attachment.filename
    end
    expect(rows['budget.xls']).to have_attributes(
      suggestion: 'released_records', rule: 'spreadsheet'
    )
    expect(rows['minutes.doc'].rule).not_to eq('format')
    expect(rows['minutes.doc'].suggestion).not_to eq('none')
  end

  it 'offers the reply’s own text as the decision letter when no file is one' do
    message = AttachmentFixtures.deliver(info_request, [], text: <<~TEXT)
      Dear Rowan Requester,

      Thank you for your request for information about fleet vehicles, which we have dealt with under the
      Freedom of Information Act 2000. We do not hold the information you asked for: the council does not
      keep a record of vehicles by depot.

      Yours sincerely,
      Information Governance Team
    TEXT
    rows = suggestions_for(message)
    expect(rows.size).to eq(1)
    expect(rows.first).
      to have_attributes(suggestion: 'decision_letter',
                         rule: 'email_decision',
                         foi_attachment_id: message.get_main_body_text_part.id)
    expect(rows.first.kind).to eq('decision_letter')
  end

  it 'gives a file or reply text that can’t be read a result of its own, and goes on with the rest' do
    letter = DocumentFixtures.decision_letter_pdf(
      requester: 'Rowan Requester',
      authority: 'Synthetic Borough Council',
      ref: 'FOI-2025-0042',
      paragraphs: ['The information you requested is held.']
    )
    message = AttachmentFixtures.deliver(
      info_request,
      [['FOI-2025-0042 response.pdf', 'application/pdf', letter],
       ['broken.pdf', 'application/pdf', DocumentFixtures.leaflet_pdf]]
    )
    allow_any_instance_of(FoiAttachment).
      to receive(:body).and_wrap_original do |body, *args|
        if body.receiver.filename == 'broken.pdf'
          raise 'synthetic unreadable part'
        end

        body.call(*args)
      end
    allow(message.get_main_body_text_part).
      to receive(:body_as_text).and_raise(StandardError,
                                          'The reply’s text couldn’t be read.')

    rows = suggestions_for(message).
      to_h { |row| [row.foi_attachment.filename, [row.suggestion, row.rule]] }
    expect(rows).to include(
      'FOI-2025-0042 response.pdf' => %w[decision_letter letter_pick],
      'broken.pdf' => %w[look unreadable]
    )
    expect(rows.values).to include(%w[none email_unreadable])

    # Stored and fresh, so the request page doesn't queue the job again.
    clear_enqueued_jobs
    reply = Disclosures::Panel.new(info_request, Ability.new(owner)).
      replies.first
    expect(reply.pending).to be(false)
    expect(Disclosures::SuggestJob).not_to have_been_enqueued
  end

  it 'works suggestions out in a job queued when a reply arrives and its text is stored, never on the request page' do
    clear_enqueued_jobs
    message = AttachmentFixtures.deliver(
      info_request,
      [['signature.png', 'image/png', DocumentFixtures.signature_png]]
    )
    expect(Disclosures::SuggestJob).not_to have_been_enqueued
    perform_enqueued_jobs(only: IncomingMessage::StoreTextJob)
    expect(Disclosures::SuggestJob).
      to have_been_enqueued.with(message.id).exactly(:once)
    expect(Disclosures::Suggestion.where(incoming_message_id: message.id)).
      to be_empty

    perform_enqueued_jobs(only: Disclosures::SuggestJob)
    expect(Disclosures::Suggestion.where(incoming_message_id: message.id).
             pluck(:display_name, :suggestion)).
      to include(%w[signature.png none])
  end

  it 'opens no more files than the AI reading does, and none too large, leaving the rest to look at' do
    files = Array.new(10) do |i|
      ["depot-#{i}.txt", 'text/plain',
       "Synthetic fleet records for depot #{i}.\n" * 10]
    end
    message = AttachmentFixtures.deliver(info_request, files)
    reads = 0
    allow(FoiAttachment::Content).
      to receive(:document_text).and_wrap_original do |original, *args|
        reads += 1
        original.call(*args)
      end
    rows = suggestions_for(message).
      reject { |row| row.rule.to_s.start_with?('email') }
    expect(reads).to eq(FoiAttachment::Content::MAX_DOCUMENTS)
    expect(rows.size).to eq(10)
    expect(rows.select { |row| row.rule == 'over_limit' }.map(&:suggestion)).
      to eq(%w[look look])
    expect(rows).to all(
      satisfy { |row| row.fresh?(FoiAttachment.find(row.foi_attachment_id)) }
    )

    stub_const('FoiAttachment::Content::MAX_DOCUMENT_BYTES', 200)
    message = AttachmentFixtures.deliver(
      info_request,
      [['big.txt', 'text/plain', "Synthetic fleet records.\n" * 20]]
    )
    expect(
      suggestions_for(message).find { |row| row.display_name == 'big.txt' }
    ).to have_attributes(suggestion: 'look', rule: 'over_limit')
  end

  it 'stops checking a reply once a file is erased or fails masking after its suggestions were saved' do
    message = AttachmentFixtures.deliver(
      info_request,
      [['records.txt', 'text/plain', "Synthetic fleet records\n" * 10],
       ['notes.txt', 'text/plain', "Synthetic depot notes\n" * 10]]
    )
    suggestions_for(message)
    parts = message.reload.foi_attachments.index_by(&:filename)
    parts.fetch('records.txt').update_columns(erased_at: Time.current)
    parts.fetch('notes.txt').update_columns(masking_failed_at: Time.current)

    clear_enqueued_jobs
    reply = Disclosures::Panel.new(info_request, Ability.new(owner)).
      replies.first
    expect(reply.pending).to be(false)
    expect(Disclosures::SuggestJob).not_to have_been_enqueued
  end

  it 'settles a reply with no readable part left, which gets no suggestions' do
    message = AttachmentFixtures.deliver(
      info_request,
      [['records.txt', 'text/plain', "Synthetic fleet records\n" * 10]]
    )
    message.reload.foi_attachments.
      each { |part| part.update_columns(erased_at: Time.current) }
    expect(suggestions_for(message)).to be_empty

    clear_enqueued_jobs
    reply = Disclosures::Panel.new(info_request, Ability.new(owner)).
      replies.first
    expect(reply.pending).to be(false)
    expect(Disclosures::SuggestJob).not_to have_been_enqueued
  end
end
