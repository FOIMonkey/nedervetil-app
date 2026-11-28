require 'spec_helper'
RSpec.describe IncomingAttention::Input do
  include_context 'with lean attention predictions'
  let(:request) {
    FactoryBot.create(:info_request, prominence: 'requester_only')
  }
  def receive_mail(text, filenames: [])
    mail = Mail.new do
      from 'officer@example.invalid'
      to 'request@example.invalid'
      message_id "#{SecureRandom.uuid}@example.invalid"
      subject 'Synthetic reply'
    end
    if filenames.empty?
      mail.content_type = 'text/plain; charset=UTF-8'
      mail.body = text
    else
      mail.content_type = 'multipart/mixed'
      main = Mail::Part.new
      main.content_type = 'text/plain; charset=UTF-8'
      main.body = text
      mail.add_part(main)
      filenames.each do |name|
        part = Mail::Part.new
        part.content_type = Marcel::MimeType.for(name: name)
        part.content_disposition = "attachment; filename=\"#{name}\""
        part.body = "Synthetic content of #{name}"
        mail.add_part(part)
      end
    end
    request.send(:create_response!, mail)
  end
  it 'uses core masking and quoted-history removal, retaining original stored email' do
    FactoryBot.create(:info_request_censor_rule, censorable: request,
                                                 text: 'PRIVATE',
                                                 replacement: '[redacted]')
    message = receive_mail("PRIVATE We received your request.\n\n> An old " \
                           "question.\n> An old answer.")
    wire = message.raw_email.file.download
    input = described_class.build(message).request
    expect(input['body']).to include('[redacted]', 'We received your request.')
    expect(input['body']).not_to include('PRIVATE', 'An old question.')
    expect(message.raw_email.file.download).to eq(wire)
    expect(input['body_shortened']).to be false
  end
  # A reply as it comes in gets the censor rules only, so the requester sees
  # an address as it came; the default masks are applied to what is sent.
  it 'never sends an email address, mobile number or sign-in link, though ' \
     'the requester sees them' do
    login = "http://#{AlaveteliConfiguration.domain}/c/synthetic123"
    message = receive_mail('Write to jane@example.org or Mobile: 07700 ' \
                           "900123, or see #{login} .")
    input = described_class.build(message).request
    expect(input['body']).
      not_to include('jane@example.org', '07700 900123', login)
    expect(input['body']).to include('[email address]', '[mobile number]')
    expect(message.get_main_body_text_folded).
      to include('jane@example.org', '07700 900123', login)
  end

  it 'logs which error left a scanned part unread, by its class' do
    part = FactoryBot.create(:pdf_attachment)
    allow(part).to receive(:body).and_raise(NoMethodError, 'jane@example.org')
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(IncomingAttention::Outcome::Input.scanned_text(part)).to be_nil
    expect(Rails.logger).to have_received(:warn).
      with("request_outcome_scanned_text_failed attachment_id=#{part.id} " \
           'NoMethodError')
  end

  it 'logs which error stopped the input being prepared, by its class' do
    message = receive_mail('Synthetic reply')
    allow(message).to receive(:parse_raw_email).
      and_raise(NoMethodError, 'Synthetic reply')
    allow(Rails.logger).to receive(:warn).and_call_original
    expect { described_class.build(message) }.
      to raise_error(described_class::Unavailable, 'input_preparation_failed')
    expect(Rails.logger).to have_received(:warn).
      with('incoming_attention_input_preparation_failed ' \
           "message_id=#{message.id} NoMethodError")
  end

  it 'sends redacted document filenames and only the number of images' do
    FactoryBot.create(:info_request_censor_rule, censorable: request,
                                                 text: 'SECRET',
                                                 replacement: 'x')
    message = receive_mail(
      'Here is an update.',
      filenames: ['SECRET report.pdf', 'J Smith passport.png', 'logo.SVG',
                  'badge.ico']
    )
    input = described_class.build(message).request
    expect(input['attachments']).
      to eq('available' => true,
            'filenames' => ['x report.pdf'],
            'images_ignored' => 3)
    expect(input.to_json).not_to include('passport')
  end
  # With the mail cell down. The note a page shows in place of a reply's
  # text must never be read as the reply.
  describe 'while the reply’s mail can’t be read' do
    def refuse_reads
      allow(MailHandler::Reading).to receive(:of).
        and_raise(MailHandler::ReadRefused, 'the mail cell is down')
      allow(Rails.logger).to receive(:warn)
    end

    it 'waits for a reply nothing has read yet' do
      message = receive_mail('We received your request.')
      IncomingMessage.where(id: message.id).update_all(last_parsed: nil)
      message.foi_attachments.destroy_all
      refuse_reads

      expect { described_class.build(IncomingMessage.find(message.id)) }.
        to raise_error(described_class::Unavailable, 'masking_pending')
    end
  end

  it 'blocks erased, hidden and missing-event mail before inference' do
    message = receive_mail('Synthetic reply')
    message.response_event.destroy!
    expect { described_class.build(message) }.
      to raise_error(described_class::Unavailable, 'response_event_missing')
    message.raw_email.update!(erased_at: Time.current)
    expect { described_class.build(message) }.
      to raise_error(described_class::Unavailable, 'source_unavailable')
  end
  it 'does not require core commit, release identities or input fingerprints' do
    input = described_class.build(receive_mail('Synthetic reply')).request
    expect(input.keys).to match_array(IncomingAttention::Config::REQUEST_FIELDS)
  end
  it 'refuses a hidden main part before extracting its body' do
    message = receive_mail('HIDDEN BODY')
    message.parse_raw_email
    main = message.get_main_body_text_part
    main.update_column(:prominence, 'hidden')
    expect(Ability.new(request.user).can?(:read, main)).to be false
    expect(message).not_to receive(:get_main_body_text_unfolded)
    expect { described_class.build(message) }.
      to raise_error(described_class::Unavailable)
  end
  it 'refuses a hidden sibling filename before extracting text or metadata' do
    message = receive_mail('Visible body', filenames: ['hidden-name.pdf'])
    message.parse_raw_email
    message.foi_attachments.find_by(filename: 'hidden-name.pdf').
      update_column(:prominence, 'hidden')
    expect(message).not_to receive(:get_main_body_text_unfolded)
    expect { described_class.build(message) }.
      to raise_error(described_class::Unavailable)
  end

  it 'marks an unanalyzed Office attachment as analysis_pending, then ' \
     'allows it once analyzed or restricts it if held' do
    message = receive_mail('Please see attached.')
    message.parse_raw_email
    part = FactoryBot.create(
      :foi_attachment,
      incoming_message: message,
      filename: 'reply.docx',
      content_type:
        'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document'
    )
    part.file.attach(
      io: StringIO.new(
        OfficeFixtures.word('<w:p><w:r><w:t>Hello</w:t></w:r></w:p>')
      ),
      filename: 'reply.docx',
      content_type: part.content_type
    )
    expect(FoiAttachment::SpreadsheetHold.waiting?(part)).to be(true)
    expect { described_class.build(message.reload) }.
      to raise_error(described_class::Unavailable, 'analysis_pending')

    part.file.analyze
    expect(described_class.build(message.reload).request['attachments']).
      to include('available' => true)

    part.update_column(:prominence, 'hidden')
    expect { described_class.build(message.reload) }.
      to raise_error(described_class::Unavailable, 'source_unavailable')
  end
end
