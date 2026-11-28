require 'spec_helper'

RSpec.describe 'Request outcome on the correspondence page' do
  self.use_transactional_tests = false
  include_context 'with a separate Manage workspace'
  include_context 'with the UK refusal sections'

  before do
    @request_ids = []
    @user_ids = []
    @authority_ids = []
    @outcome_inputs = []
    allow(AlaveteliConfiguration).
      to receive(:incoming_outcome_mode).and_return('apply')
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)
    allow(IncomingAttention::Job).
      to receive(:perform_later).and_return(double('queued'))
    allow(IncomingAttention::Outcome::Job).
      to receive(:perform_later).and_return(double('queued'))
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    allow(AlaveteliFeatures.backend).
      to receive(:enabled?).with(:alaveteli_pro).and_return(true)
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
  end

  after do
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    InfoRequest.where(id: @request_ids).find_each(&:destroy!)
    PublicBody.where(id: @authority_ids).find_each(&:destroy!)
    User.where(id: @user_ids).find_each(&:destroy!)
  end

  let(:owner) {
    FactoryBot.create(:pro_user).tap { |user| @user_ids << user.id }
  }
  let(:authority) {
    FactoryBot.create(:public_body).tap { |body| @authority_ids << body.id }
  }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner,
                                     public_body: authority,
                                     prominence: 'requester_only').tap { |r|
                                       @request_ids << r.id
                                     }
  end

  let(:letter) do
    "Dear Requester\n\nThank you for your request for information, our " \
    "reference FOI 4242. " \
           "Please find the figures below. Ward A: 12. Ward B: 7. The names " \
           "of contractors are withheld under " \
           "section 43(2) of the Freedom of Information Act.\n\nYours " \
           "sincerely\nInformation Team\n"
  end

  def receive_response(extra_file: nil)
    target = info_request
    # Mail's add_file takes the name out of the hash it's given.
    extra_name = extra_file&.fetch(:filename)
    letter = self.letter
    mail = Mail.new do
      from 'synthetic-officer@example.invalid'
      to target.incoming_email
      subject 'Synthetic outcome response'
      message_id "outcome-#{SecureRandom.uuid}@example.invalid"
      date Time.utc(2026, 10, 9, 12)
      text_part { body "Please see the attached response to your request.\n" }
      add_file filename: 'FOI 4242 Response.txt', content: letter
      add_file filename: 'Your rights summary.txt',
               content: "What rights do I have under the Act? You may ask " \
                        "for " \
                        "a review. " * 5
      add_file(extra_file) if extra_file
    end
    target.send(:create_response!,
                mail,
                message_id: mail.message_id,
                message_checksum: Digest::SHA1.hexdigest(mail.encoded))
    message = target.incoming_messages.order(:id).last
    read_by_analyzer(message, extra_name) if extra_name
    message
  end

  # A zip waits for the analyzer's spreadsheet scan before the reading can use
  # it (FoiAttachment::SpreadsheetHold.waiting?): read, as if the scan had run.
  def read_by_analyzer(message, filename)
    message.parse_raw_email!
    parts = message.foi_attachments.reload
    part = parts.find { |each| each.filename == filename } or
      raise "no #{filename} in the reply: #{parts.map(&:filename).inspect}"
    blob = part.file.blob
    blob.update!(metadata: blob.metadata.merge(analyzed: true))
  end

  def worker_result(call = 'some', reasons: ['cites_refusal'], withheld_under: ['Section 43'], mentions: ['Section 43'])
    { 'inference_status' => 'complete',
      'call' => call,
      'reasons' => reasons,
      'withheld_under' => withheld_under,
      'mentions' => mentions, 'input_truncated' => false, 'error_code' => nil,
      'diagnostics' => { 'scores' => { 'opaque' => 1 },
                         'signals' => { 'withholding' => ['Section 43'] } } }
  end

  def assess(message, result: worker_result)
    row = IncomingAttention::Prediction.find_by!(
      incoming_message_id: message.id
    )
    row.update!(status: 'complete',
                route: 'REVIEW',
                needs_check: true,
                eligible: true,
                restrictions: [],
                response_event_id: message.response_event.id)
    client = IncomingAttention::Outcome::Client.new(transport: ->(input) do
      @outcome_inputs << input.deep_dup
      [200, JSON.generate(input.slice('contract_version',
                                      'message_id',
                                      'info_request_id').merge(result))]
    end)
    allow(IncomingAttention::Outcome::Job).
      to receive(:client_factory).and_return(-> { client })
    IncomingAttention::Outcome.queue(row, message)
    IncomingAttention::Outcome::Job.new.perform(row.id)
    row.reload
  end

  def page
    Nokogiri::HTML(response.body)
  end

  # A reply as it comes in gets the censor rules only, so the requester sees
  # these as they came; every mask is applied to what the AI is sent.
  it 'never sends an email address, mobile number or sign-in link' do
    login = "http://#{AlaveteliConfiguration.domain}/c/synthetic123"
    hidden = ['synthetic.officer@example.org', '07700 900123', login]
    said = "Write to #{hidden[0]}, Mobile: #{hidden[1]}, or see #{login} ."
    target = info_request
    letter = "#{self.letter}#{said}\n"
    mail = Mail.new do
      from 'synthetic-officer@example.invalid'
      to target.incoming_email
      subject 'Synthetic outcome response'
      message_id "outcome-#{SecureRandom.uuid}@example.invalid"
      date Time.utc(2026, 10, 9, 12)
      text_part do
        body "Please see the attached response. #{said}\n\n" \
             "On 1 Oct you wrote:\n> #{said}\n> My question.\n"
      end
      add_file filename: 'FOI 4242 Response.txt', content: letter
    end
    target.send(:create_response!,
                mail,
                message_id: mail.message_id,
                message_checksum: Digest::SHA1.hexdigest(mail.encoded))
    message = target.incoming_messages.order(:id).last

    assess(message)
    sent = @outcome_inputs.first
    expect(sent['reply_unfolded']).to be_present
    expect(sent['documents'].first['text']).to include('Ward A: 12')
    read = [sent['reply'], sent['reply_unfolded'],
            sent['documents'].first['text']].join("\n")
    hidden.each { |text| expect(read).not_to include(text) }
    expect(message.reload.get_main_body_text_folded).to include(hidden[0])
  end

  it 'reads the request, the reply and the picked letter, but not the leaflet' do
    outgoing = info_request.outgoing_messages.first
    outgoing.
      update_columns(body: outgoing.body + "\nI am asking about section 31 " \
                                           "decisions.\nReply to " \
                                           "synthetic.requester@example.com " \
                                           "please.")
    row = assess(receive_response)
    sent = @outcome_inputs.first
    expect(sent['request_text']).to include('section 31 decisions')
    expect(sent['request_text']).
      not_to include('synthetic.requester@example.com')
    expect(sent['reply']).to include('Please see the attached response')
    expect(sent['documents'].map { |doc| doc.slice('name', 'letter') }).
      to eq([{ 'name' => 'FOI 4242 Response.txt', 'letter' => true }])
    expect(sent['documents'].first['text']).to include('Ward A: 12')
    expect(sent.to_json).not_to include('What rights do I have')
    # The request's own mention of section 31 is not a refusal citation.
    expect(sent['cited_sections']).to eq(['Section 43'])
    expect(sent).
      to include('omitted_documents' => 0,
                 'strict_documents' => false,
                 'request_shortened' => false,
                 'text_shortened' => false)
    expect(row.outcome_signals).
      to include('letter' => 'FOI 4242 Response.txt', 'cited' => ['Section 43'],
                 'withholding' => ['Section 43'],
                 'reasons' => ['cites_refusal'],
                 'withheld_under' => ['Section 43'])
    expect(row.outcome_scores).to eq('opaque' => 1)
  end

  it 'applies "some", names what was withheld, and lets the requester confirm' do
    message = receive_response
    row = assess(message)
    expect(row).
      to have_attributes(outcome_call: 'some',
                         outcome_applied_state: 'partially_successful')
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    note = page.at_css('.receipt .request-outcome')
    expect(note.text).
      to include('Some information released: withheld under Section 43')
    expect(page.at_css("#reply-#{message.id} .feed__meta").text).
      to include('Some information released')
    expect(response.body).
      not_to include('information_given', 'applies_other_exemption')

    form = note.at_css('form.request-outcome__confirm')
    post form['action'], params: { authenticity_token: form.at_css(
      'input[name=authenticity_token]'
    )&.[]('value'), classification: { described_state: 'partially_successful' },
                                   last_info_request_event_id: form.at_css(
                                     'input[name=last_info_request_event_id]'
                                   )['value'] }
    expect(row.reload.human_reviewed_at).to be_present
    expect(row.outcome_overridden_from).to be_nil
    expect(info_request.reload.described_state).to eq('partially_successful')
    get "/request/#{info_request.url_title}"
    expect(page.at_css("#reply-#{message.id} .request-outcome")).to be_nil
  end

  it 'shows a suspended requester the reading but nothing to confirm' do
    message = receive_response
    assess(message)
    owner.update!(ban_text: 'Spam')
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    note = page.at_css('.receipt .request-outcome')
    expect(note.text).
      to include('Some information released: withheld under Section 43')
    expect(note.at_css('form')).to be_nil
  end

  it 'sends nothing when the original request is hidden from the requester' do
    info_request.outgoing_messages.first.update_columns(prominence: 'hidden')
    row = assess(receive_response)
    expect(@outcome_inputs).to be_empty
    expect(row).
      to have_attributes(outcome_status: 'restricted',
                         outcome_signals: { 'error' => 'request_unavailable' })
  end

  it 'checks again just before sending, so an attachment hidden during extraction stops the call' do
    message = receive_response
    allow(IncomingAttention::Outcome::Input).
      to receive(:build).and_wrap_original do |original, *args|
      built = original.call(*args)
      message.foi_attachments.find_by(filename: 'FOI 4242 Response.txt').
        update_columns(prominence: 'hidden')
      built
    end
    row = assess(message)
    expect(@outcome_inputs).to be_empty
    expect(row).
      to have_attributes(outcome_status: 'restricted',
                         outcome_signals: { 'error' => 'source_changed' })
  end

  it 'stops the call when a document is replaced during extraction' do
    message = receive_response
    allow(IncomingAttention::Outcome::Input).
      to receive(:build).and_wrap_original do |original, *args|
      built = original.call(*args)
      message.foi_attachments.find_by(filename: 'FOI 4242 Response.txt').
        update_columns(masked_at: Time.current, updated_at: Time.current + 1)
      built
    end
    row = assess(message)
    expect(@outcome_inputs).to be_empty
    expect(row).
      to have_attributes(outcome_status: 'restricted',
                         outcome_signals: { 'error' => 'source_changed' })
  end

  it 'stops the call when a censor rule changes during extraction' do
    rule = FactoryBot.create(:info_request_censor_rule,
                             censorable: info_request,
                             text: 'Ward Z')
    message = receive_response
    allow(IncomingAttention::Outcome::Input).
      to receive(:build).and_wrap_original do |original, *args|
      built = original.call(*args)
      rule.update_columns(text: 'Ward A', updated_at: Time.current + 5)
      built
    end
    row = assess(message)
    expect(@outcome_inputs).to be_empty
    expect(row.outcome_signals).to eq('error' => 'source_changed')
  end

  it 'sends nothing when the extracted document is replaced before extraction returns' do
    message = receive_response
    FactoryBot.create(:admin_user).tap { |user| @user_ids << user.id }
    allow(FoiAttachment::Content).
      to receive(:document_text).and_wrap_original do |original, part|
      text = original.call(part)
      if part.filename == 'FOI 4242 Response.txt'
        FoiAttachment.find(part.id).replace_file!("[redacted]\n")
      end
      text
    end

    row = assess(message)
    expect(@outcome_inputs).to be_empty
    expect(row).
      to have_attributes(outcome_status: 'restricted',
                         outcome_signals: { 'error' => 'source_changed' })
  end

  it 'sends nothing when the main body changes while its text is being read' do
    message = receive_response
    allow_any_instance_of(IncomingMessage).
      to receive(:get_main_body_text_folded).and_wrap_original do |original|
      text = original.call
      if original.receiver.id == message.id
        original.receiver.get_main_body_text_part.update_columns(
          masked_at: Time.current,
          updated_at: Time.current + 1
        )
      end
      text
    end

    row = assess(message)
    expect(@outcome_inputs).to be_empty
    expect(row.outcome_signals).to eq('error' => 'source_changed')
  end

  it 'sends nothing when a censor rule changes before the source snapshot is finished' do
    rule = FactoryBot.create(:info_request_censor_rule,
                             censorable: info_request,
                             text: 'Ward Z')
    message = receive_response
    allow(FoiAttachment::Content).
      to receive(:document_text).and_wrap_original do |original, part|
      text = original.call(part)
      rule.update_columns(text: 'Ward A', updated_at: Time.current + 5)
      text
    end

    row = assess(message)
    expect(@outcome_inputs).to be_empty
    expect(row.outcome_signals).to eq('error' => 'source_changed')
  end

  it 'still sends an unchanged reply when core first has to mask its parts' do
    message = receive_response
    message.parse_raw_email
    message.foi_attachments.update_all(masked_at: nil)
    row = assess(message)
    expect(@outcome_inputs.size).to eq(1)
    expect(@outcome_inputs.first['documents'].first['text']).
      to include('Ward A: 12')
    expect(row.outcome_status).to eq('complete')
  end

  it 'tells the Worker about a document it could not read, and applies its reading' do
    row = assess(receive_response(extra_file: { filename: 'records.zip',
                                                content: 'PK' + ('x' * 200) }))
    expect(@outcome_inputs.first).
      to include('omitted_documents' => 1, 'strict_documents' => false)
    expect(@outcome_inputs.first.to_json).not_to include('records.zip')
    expect(row.outcome_signals['omitted']).
      to eq('records.zip' => 'unreadable_type')
    expect(info_request.reload.described_state).to eq('partially_successful')
  end

  it 'passes the strict documents setting and leaves core asking when the Worker is not sure' do
    allow(AlaveteliConfiguration).
      to receive(:incoming_outcome_strict_documents).and_return(true)
    row = assess(receive_response(extra_file: { filename: 'records.zip',
                                                content: 'PK' + ('x' * 200) }),
      result: worker_result('unsure', reasons: ['documents_omitted'],
                                      withheld_under: [],
                                      mentions: []))
    expect(@outcome_inputs.first['strict_documents']).to be true
    expect(row.outcome_call).to eq('unsure')
    expect(info_request.reload.awaiting_description?).to be true
  end

  it 'tells the requester when it cannot tell, and leaves core asking' do
    message = receive_response
    assess(message, result: worker_result('unsure', reasons: ['borderline'],
                                                    withheld_under: [],
                                                    mentions: ['Section 43']))
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    expect(page.at_css('.request-outcome').text).
      to include('couldn’t tell')
    expect(info_request.reload.awaiting_description?).to be true
  end
end
