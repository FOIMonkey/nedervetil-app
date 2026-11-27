# == Schema Information
#
# Table name: foi_attachments
#
#  id                    :integer          not null, primary key
#  content_type          :text
#  filename              :text
#  charset               :text
#  display_size          :text
#  url_part_number       :integer
#  within_rfc822_subject :text
#  incoming_message_id   :integer
#  hexdigest             :string(32)
#  created_at            :datetime
#  updated_at            :datetime
#  prominence            :string           default("requester_only"), not null
#  prominence_reason     :text
#  masked_at             :datetime
#  erased_at             :datetime
#  masking_failed_at     :datetime
#  black_masked          :boolean          default(FALSE), not null
#

require 'spec_helper'
require 'models/concerns/message_prominence'

RSpec.describe FoiAttachment do
  it_behaves_like 'concerns/message_prominence', :body_text

  describe '.binary' do
    subject { described_class.binary }

    before do
      FactoryBot.create(:body_text)
      FactoryBot.create(:html_attachment)
    end

    let(:binary_attachments) do
      [FactoryBot.create(:pdf_attachment),
       FactoryBot.create(:rtf_attachment),
       FactoryBot.create(:jpeg_attachment),
       FactoryBot.create(:unknown_attachment)]
    end

    it { is_expected.to match_array(binary_attachments) }
  end

  describe '.erased' do
    subject { described_class.erased }

    let!(:erased_attachment) { FactoryBot.create(:body_text, :erased) }
    let!(:non_erased_attachment) { FactoryBot.create(:body_text) }

    it { is_expected.to include(erased_attachment) }
    it { is_expected.to_not include(non_erased_attachment) }
  end

  describe '.not_erased' do
    subject { described_class.not_erased }

    let!(:erased_attachment) { FactoryBot.create(:body_text, :erased) }
    let!(:non_erased_attachment) { FactoryBot.create(:body_text) }

    it { is_expected.to_not include(erased_attachment) }
    it { is_expected.to include(non_erased_attachment) }
  end

  describe '.masked' do
    subject { described_class.masked }

    let!(:masked_attachment) { FactoryBot.create(:body_text) }
    let!(:unmasked_attachment) { FactoryBot.create(:body_text, :unmasked) }

    it { is_expected.to include(masked_attachment) }
    it { is_expected.to_not include(unmasked_attachment) }
  end

  describe '.unmasked' do
    subject { described_class.unmasked }

    let!(:masked_attachment) { FactoryBot.create(:body_text) }
    let!(:unmasked_attachment) { FactoryBot.create(:body_text, :unmasked) }

    it { is_expected.to_not include(masked_attachment) }
    it { is_expected.to include(unmasked_attachment) }
  end

  describe '#body=' do
    it "sets the body" do
      attachment = FoiAttachment.new
      attachment.body = "baz"
      expect(attachment.body).to eq("baz")
    end

    it "sets the size" do
      attachment = FoiAttachment.new
      attachment.body = "baz"
      expect(attachment.body).to eq("baz")
      expect(attachment.display_size).to eq("0K")
    end

    it 'can parse raw email and read attachment inside DB transaction' do
      im = FactoryBot.create(:plain_incoming_message)
      FoiAttachment.transaction do
        expect { im.get_attachment_text_full }.to_not raise_error
        main_part = im.get_main_body_text_part
        expect(main_part.body).to match(/That's so totally a rubbish question/)
      end
    end

    it 'does not update hexdigest if already present' do
      attachment = FoiAttachment.new(hexdigest: 'ABC')
      expect { attachment.body = 'foo' }.to_not(change { attachment.hexdigest })
    end

    it 'does not reset existing blob key' do
      attachment = FactoryBot.create(
        :foi_attachment, :unmasked, body: 'unmasked'
      )

      expect { attachment.update(body: 'masked', masked_at: Time.now) }.
        to_not(change { attachment.file_blob.key })
    end

    it 'does not reset existing blob metadata' do
      attachment = FactoryBot.create(
        :foi_attachment, :unmasked, body: 'unmasked'
      )

      expect { attachment.update(body: 'masked', masked_at: Time.now) }.
        to_not(change { attachment.file_blob.metadata })
    end

    it 'persists changes to existing blob checksum' do
      attachment = FactoryBot.create(
        :foi_attachment, :unmasked, body: 'unmasked'
      )

      expect { attachment.update(body: 'masked', masked_at: Time.now) }.
        to(change { attachment.file_blob.checksum })
      expect(attachment.file_blob.changed?).to eq false
    end

    it 'keeps a masked_at stamped on a new record alongside the body' do
      stamped = 1.hour.ago
      attachment = FoiAttachment.new(masked_at: stamped, body: 'bytes')

      # The attribute cast keeps microseconds; the Time carries nanoseconds.
      expect(attachment.masked_at).to be_within(0.001).of(stamped)
    end
  end

  describe '#masked?' do
    it 'is true after a fault, as the stored file is still served' do
      attachment = FactoryBot.create(:body_text,
                                     masking_failed_at: Time.zone.now)

      expect(attachment).to be_masked
      expect(attachment).to be_masking_failed
    end
  end

  describe '#body' do
    context 'when erased' do
      let(:foi_attachment) { FactoryBot.create(:body_text, :erased) }

      it 'raises ErasedError error' do
        expect { foi_attachment.body }.to raise_error(
          FoiAttachment::ErasedError,
          "attachment has been erased (ID=#{foi_attachment.id})"
        )
      end
    end

    context 'when masking hit a fault and the part waits to be masked again' do
      let(:foi_attachment) do
        FactoryBot.create(
          :body_text, :unmasked, masking_failed_at: Time.zone.now
        )
      end

      it 'masks it again, so the requester gets a copy' do
        expect(FoiAttachment::MaskJob).to receive(:perform_now).
          and_call_original
        expect(foi_attachment.body).to be_present
      end
    end

    context 'when masked' do
      let(:foi_attachment) { FactoryBot.create(:body_text) }

      it 'returns a binary encoded string when newly created' do
        expect(foi_attachment.body.encoding.to_s).to eq('ASCII-8BIT')
      end

      it 'returns a binary encoded string when saved' do
        foi_attachment_2 = FoiAttachment.find(foi_attachment.id)
        expect(foi_attachment_2.body.encoding.to_s).to eq('ASCII-8BIT')
      end
    end

    context 'when unmasked and stored file is present' do
      let(:foi_attachment) { FactoryBot.create(:body_text, :unmasked) }

      it 'calls the FoiAttachment::MaskJob now and returns the masked body' do
        expect(FoiAttachment::MaskJob).to receive(:perform_now).
          with(foi_attachment).
          and_invoke(-> (_) {
            foi_attachment.update(body: 'maskedbody', masked_at: Time.zone.now)
          })

        expect(foi_attachment.body).to eq('maskedbody')
      end

      it 'raises MissingError if masking does not store a file' do
        foi_attachment.reload
        allow(FoiAttachment::MaskJob).to receive(:perform_now)

        expect { foi_attachment.body }.to raise_error(
          FoiAttachment::MissingError,
          "attachment still missing after masking (ID=#{foi_attachment.id})"
        )
      end
    end
  end

  describe '#body_as_text' do
    context 'when erased' do
      let(:foi_attachment) { FactoryBot.create(:body_text, :erased) }

      it 'raises ErasedError error' do
        expect { foi_attachment.body_as_text }.to raise_error(
          FoiAttachment::ErasedError,
          "attachment has been erased (ID=#{foi_attachment.id})"
        )
      end
    end

    it 'has a valid UTF-8 string when newly created' do
      foi_attachment = FactoryBot.create(:body_text)
      expect(foi_attachment.body_as_text.string.encoding.to_s).to eq('UTF-8')
      expect(foi_attachment.body_as_text.string.valid_encoding?).to be true
    end

    it 'has a valid UTF-8 string when saved' do
      foi_attachment = FactoryBot.create(:body_text)
      foi_attachment = FoiAttachment.find(foi_attachment.id)
      expect(foi_attachment.body_as_text.string.encoding.to_s).to eq('UTF-8')
      expect(foi_attachment.body_as_text.string.valid_encoding?).to be true
    end

    it 'has a true scrubbed? value if the body has been coerced to valid UTF-8' do
      foi_attachment = FactoryBot.create(:body_text)
      foi_attachment.body =
        "\x0FX\x1C\x8F\xA4\xCF\xF6\x8C\x9D\xA7\x06\xD9\xF7\x90lo"
      expect(foi_attachment.body_as_text.scrubbed?).to be true
    end

    it 'has a false scrubbed? value if the body has not been coerced to valid UTF-8' do
      foi_attachment = FactoryBot.create(:body_text)
      foi_attachment.body = "κόσμε"
      expect(foi_attachment.body_as_text.scrubbed?).to be false
    end
  end

  describe '#default_body' do
    context 'when erased' do
      let(:foi_attachment) { FactoryBot.create(:body_text, :erased) }

      it 'raises ErasedError error' do
        expect { foi_attachment.default_body }.to raise_error(
          FoiAttachment::ErasedError,
          "attachment has been erased (ID=#{foi_attachment.id})"
        )
      end
    end

    it 'returns valid UTF-8 for a text attachment' do
      foi_attachment = FactoryBot.create(:body_text)
      expect(foi_attachment.default_body.encoding.to_s).to eq('UTF-8')
      expect(foi_attachment.default_body.valid_encoding?).to be true
    end

    it 'returns binary for a PDF attachment' do
      foi_attachment = FactoryBot.create(:pdf_attachment)
      expect(foi_attachment.default_body.encoding.to_s).to eq('ASCII-8BIT')
    end
  end

  describe '#apply_censor_rules' do
    let(:attachment) { FactoryBot.create(:body_text) }
    let(:text) { 'Zebracorn wrote from jane@example.org.' }

    it 'applies the censor rules, not the default masks' do
      FactoryBot.create(:info_request_censor_rule,
                        censorable: attachment.info_request,
                        text: 'Zebracorn', replacement: '[hidden]')

      expect(attachment.apply_censor_rules(text, 'text/plain',
                                           redacted_attribute: :body)).
        to eq('[hidden] wrote from jane@example.org.')
    end

    it 'runs no masker when no censor rule applies' do
      attachment
      expect(AlaveteliTextMasker).not_to receive(:apply_masks)
      expect(attachment.apply_censor_rules(text, 'application/pdf',
                                           redacted_attribute: :body)).
        to eq(text)
    end
  end

  describe '#masked_default_body', feature: :redaction_tracking do
    subject { foi_attachment.masked_default_body }

    let(:foi_attachment) { FactoryBot.create(:body_text) }

    let!(:censor_rule) do
      FactoryBot.create(:info_request_censor_rule,
                        censorable: foi_attachment.info_request,
                        text: 'hereisthetext', replacement: '[REDACTED]')
    end

    it 'masks the body served in a request zip' do
      is_expected.to include('[REDACTED]')
    end

    it 'serves the stored body if a PDF cannot be masked again' do
      allow(foi_attachment).to receive(:apply_censor_rules).
        and_raise(AlaveteliTextMasker::PDFMaskingError)
      is_expected.to eq(foi_attachment.default_body)
    end

    it 'serves the stored body if a rule times out' do
      allow(foi_attachment).to receive(:apply_censor_rules).
        and_raise(Regexp::TimeoutError)
      is_expected.to eq(foi_attachment.default_body)
    end

    it 'records the redaction against :default_body' do
      subject

      expect(censor_rule.redactions.pluck(:redacted_attribute)).
        to include('default_body')
    end
  end

  describe '#unmasked_body' do
    let(:foi_attachment) { FactoryBot.create(:body_text) }

    context 'when raw email erased' do
      before do
        allow(foi_attachment).to receive(:raw_email).
          and_return(double(id: 123, kept?: false))
      end

      it 'raises RawEmail::ErasedError error' do
        expect { foi_attachment.unmasked_body }.to raise_error(
          RawEmail::Erasable::ErasedError, 'email is no longer kept (ID=123)'
        )
      end
    end
  end

  describe 'masked?' do
    let(:foi_attachment) do
      FoiAttachment.new(body: 'foo', masked_at: Time.zone.now)
    end

    subject { foi_attachment.masked? }

    it { is_expected.to eq(true) }

    context 'without file attached' do
      let(:foi_attachment) { FoiAttachment.new(masked_at: Time.zone.now) }
      it { is_expected.to eq(false) }
    end

    context 'without masked_at' do
      let(:foi_attachment) { FoiAttachment.new(body: 'foo') }
      it { is_expected.to eq(false) }
    end

    context 'when masked_at is in the future' do
      let(:foi_attachment) do
        FoiAttachment.new(body: 'foo', masked_at: Time.zone.now + 1.day)
      end

      it { is_expected.to eq(false) }
    end
  end

  describe '#main_body_part?' do
    subject { attachment.main_body_part? }

    let(:message) { FactoryBot.create(:incoming_message, :with_pdf_attachment) }

    context 'when the attachment is the main body' do
      let(:attachment) { message.get_main_body_text_part }
      it { is_expected.to eq(true) }
    end

    context 'when the attachment is not the main body' do
      let(:attachment) { message.get_attachments_for_display.first }
      it { is_expected.to eq(false) }
    end
  end

  describe '#filename=' do
    it 'strips null bytes' do
      attachment = FactoryBot.build(:pdf_attachment)
      attachment.filename = "Tender Loving Care Trust (Europe).pdf\u0000"
      expect(attachment.filename).to eq('Tender Loving Care Trust (Europe).pdf')
    end

    it 'strips line breaks before checking the extension' do
      attachment = FactoryBot.build(:pdf_attachment)
      attachment.filename = "report.pdf\n.html"
      expect(attachment.filename).to eq('report.pdf.html.pdf')
    end
  end

  describe '#ensure_filename!' do
    it 'should create a filename for an instance with a blank filename' do
      attachment = FoiAttachment.new
      attachment.filename = ''
      attachment.ensure_filename!
      expect(attachment.filename).to eq('attachment.bin')
    end
  end

  describe '#body_to_text' do
    subject { foi_attachment.body_to_text }

    context 'when not erased' do
      let(:foi_attachment) { FactoryBot.create(:body_text) }

      before do
        allow(AttachmentToText).
          to receive(:new).
          with(foi_attachment).
          and_return(instance_double(AttachmentToText, to_text: 'some text'))
      end

      it { is_expected.to eq('some text') }
    end

    context 'when erased' do
      let(:foi_attachment) { FactoryBot.create(:body_text, :erased) }

      it 'raises ErasedError' do
        expect { subject }.to raise_error(
          FoiAttachment::ErasedError,
          "attachment has been erased (ID=#{foi_attachment.id})"
        )
      end
    end
  end

  describe '#name_of_content_type' do
    subject { foi_attachment.name_of_content_type }

    before do
      allow_any_instance_of(described_class).
        to receive(:content_type_names).
        and_return('content/named' => 'Named content')
    end

    let(:foi_attachment) do
      FactoryBot.build(:foi_attachment, content_type: content_type)
    end

    context 'when the content_type has a name' do
      let(:content_type) { 'content/named' }
      it { is_expected.to eq('Named content') }
    end

    context 'when the content_type has no name' do
      let(:content_type) { 'content/unnamed' }
      it { is_expected.to be_nil }
    end
  end

  describe '#extra_note' do
    subject { foi_attachment.extra_note }

    context 'with a delivery status notification' do
      let(:foi_attachment) do
        FactoryBot.create(:delivery_status_notification_attachment)
      end

      let(:note) do
        'DSN: 4.4.0 Other or undefined network or routing status'
      end

      it { is_expected.to eq(note) }
    end

    context 'with any other content type' do
      let(:foi_attachment) { FactoryBot.build(:rtf_attachment) }
      it { is_expected.to be_nil }
    end
  end

  describe '#expire' do
    let(:incoming_message) { FactoryBot.create(:incoming_message) }
    let(:foi_attachment) { incoming_message.foi_attachments.first }

    it 'delegates to info_request' do
      expect(foi_attachment.info_request).to receive(:expire)
      foi_attachment.expire
    end
  end

  describe '#log_event' do
    let(:incoming_message) { FactoryBot.create(:incoming_message) }
    let(:foi_attachment) { incoming_message.foi_attachments.first }

    it 'delegates to info_request' do
      expect(foi_attachment.info_request).
        to receive(:log_event).with('edit', {})
      foi_attachment.log_event('edit', {})
    end
  end

  describe '#update_and_log_event' do
    let(:incoming_message) { FactoryBot.create(:incoming_message) }
    let(:info_request) { incoming_message.info_request }
    let(:foi_attachment) { incoming_message.foi_attachments.first }

    def last_event
      info_request.info_request_events.last
    end

    it 'updates and logs edit_attachment event' do
      expect do
        foi_attachment.update_and_log_event(prominence: 'hidden')
      end.to(change { last_event })

      expect(last_event.event_type).to eq('edit_attachment')
    end

    it 'logs prominence and reason changes' do
      foi_attachment.update_and_log_event(
        prominence: 'hidden', prominence_reason: 'just because'
      )
      expect(last_event.params[:old_prominence]).to eq('requester_only')
      expect(last_event.params[:prominence]).to eq('hidden')
      expect(last_event.params[:old_prominence_reason]).to be_nil
      expect(last_event.params[:prominence_reason]).to eq('just because')
    end

    it 'logs additional event data' do
      foi_attachment.update_and_log_event(
        prominence: 'hidden', event: { editor: 'me' }
      )
      expect(last_event.params[:editor]).to eq('me')
    end

    it 'does not log event if update fails' do
      expect do
        foi_attachment.update_and_log_event(prominence: nil)
      end.to_not(change { last_event })
    end
  end

  describe '#update_and_log_event!' do
    let(:incoming_message) { FactoryBot.create(:incoming_message) }
    let(:info_request) { incoming_message.info_request }
    let(:foi_attachment) { incoming_message.foi_attachments.first }

    def last_event
      info_request.info_request_events.last
    end

    it 'updates and logs edit_attachment event' do
      expect do
        foi_attachment.update_and_log_event!(prominence: 'hidden')
      end.to(change { last_event })

      expect(last_event.event_type).to eq('edit_attachment')
    end

    it 'logs prominence and reason changes' do
      foi_attachment.update_and_log_event!(
        prominence: 'hidden', prominence_reason: 'just because'
      )
      expect(last_event.params[:old_prominence]).to eq('requester_only')
      expect(last_event.params[:prominence]).to eq('hidden')
      expect(last_event.params[:old_prominence_reason]).to be_nil
      expect(last_event.params[:prominence_reason]).to eq('just because')
    end

    it 'logs additional event data' do
      foi_attachment.update_and_log_event!(
        prominence: 'hidden', event: { editor: 'me' }
      )
      expect(last_event.params[:editor]).to eq('me')
    end

    it 'raises an exception if update fails' do
      expect do
        foi_attachment.update_and_log_event!(prominence: nil)
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'does not log event if update fails' do
      expect do
        foi_attachment.update_and_log_event!(prominence: nil)
      rescue ActiveRecord::RecordInvalid
        # expected
      end.to_not(change { last_event })
    end

    it 'raises an exception if logging fails' do
      allow(foi_attachment).to receive(:log_event).
        and_raise(ActiveRecord::RecordInvalid)

      expect do
        foi_attachment.update_and_log_event!(prominence: 'hidden')
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'rolls back update if logging fails' do
      allow(foi_attachment).to receive(:log_event).
        and_raise(ActiveRecord::RecordInvalid)

      expect do
        foi_attachment.update_and_log_event!(prominence: 'hidden')
      rescue ActiveRecord::RecordInvalid
        # expected
      end.to_not(change { foi_attachment.reload.prominence })
    end
  end

  describe '#unmasked_parts' do
    let(:info_request) { FactoryBot.create(:info_request) }

    def delivered(name, type, body)
      message = AttachmentFixtures.deliver(info_request, [[name, type, body]])
      attachment = message.get_attachments_for_display.
                   find { |part| part.filename == name }
      FoiAttachment.find(attachment.id)
    end

    def masked(attachment)
      attachment.mask
      FoiAttachment.find(attachment.id)
    end

    # Masking runs only while a black censor rule applies.
    before do
      FactoryBot.create(:info_request_censor_rule, censorable: info_request,
                                                   text: 'Zebracorn',
                                                   colour: 'black')
    end

    let(:locked_pdf) do
      AttachmentFixtures.encrypted_pdf(
        AttachmentFixtures.pdf(
          pages: [AttachmentFixtures.letter_page(secret: 'Synthetic')]
        )
      )
    end

    it 'records on the stored file a PDF that went out as it came' do
      attachment = masked(delivered('locked.pdf', 'application/pdf',
                                    locked_pdf))

      expect(attachment.unmasked_parts).
        to eq([AlaveteliTextMasker::UNMASKED_PDF])
      expect(attachment.file_blob.metadata['unmasked_parts']).
        to eq([AlaveteliTextMasker::UNMASKED_PDF])
    end

    it 'keeps the record when the stored PDF is kept by its mask key' do
      attachment = masked(delivered('locked.pdf', 'application/pdf',
                                    locked_pdf))
      attachment.update_column(:masked_at, nil)

      expect(masked(attachment).unmasked_parts).
        to eq([AlaveteliTextMasker::UNMASKED_PDF])
    end

    it 'records an Office document that went out as it came' do
      docx = 'application/vnd.openxmlformats-officedocument' \
             '.wordprocessingml.document'
      attachment = masked(delivered('notes.docx', docx,
                                    load_file_fixture('lorem.docx')))

      expect(attachment.unmasked_parts).
        to eq([AlaveteliTextMasker::UNMASKED_ZIP])
    end

    it 'records nothing for a file masking reached' do
      attachment = masked(delivered('notes.txt', 'text/plain', "Notes.\n"))
      expect(attachment.unmasked_parts).to be_empty
      expect(attachment.file_blob.metadata).not_to have_key('unmasked_parts')
    end

    it 'drops an old record when the file is masked again' do
      attachment = masked(delivered('notes.txt', 'text/plain', "Notes.\n"))
      attachment.file_blob.update!(
        metadata: attachment.file_blob.metadata.
          merge('unmasked_parts' => ['an old part'])
      )
      attachment.update_column(:masked_at, nil)

      expect(masked(attachment).unmasked_parts).to be_empty
    end

    it 'shows nothing while the stored file is not masked yet' do
      attachment = masked(delivered('locked.pdf', 'application/pdf',
                                    locked_pdf))
      attachment.update_columns(masked_at: nil)

      expect(FoiAttachment.find(attachment.id).unmasked_parts).to be_empty
    end
  end

  describe '#mask' do
    subject { attachment.mask }

    let(:info_request) { FactoryBot.create(:info_request_with_html_attachment) }
    let(:incoming_message) { info_request.incoming_messages.first }
    let(:attachment) { incoming_message.foi_attachments.last }

    it 'updates masked_at' do
      info_request.censor_rules.create!(
        text: 'dull', replacement: 'boring', colour: 'black',
        last_edit_editor: 'unknown', last_edit_comment: 'none'
      )

      expect { subject }.to change { attachment.masked_at }.to(Time)
    end

    context 'when masking hits a fault' do
      before do
        allow(attachment).to receive(:apply_censor_rules).
          and_raise(AlaveteliTextMasker::PDFMaskingError, 'synthetic')
      end

      it 'serves the part as it came, sanitised, and records the fault' do
        subject
        attachment.reload
        expect(attachment).to be_masking_failed
        expect(attachment).to be_masked
        expect(attachment.body).to include('dull')
        expect(attachment.body).not_to include('<script>')
        expect(attachment.masking_fault).to eq(
          [:as_it_came, 'AlaveteliTextMasker::PDFMaskingError: synthetic']
        )
      end
    end

    context 'with HTML attachment' do
      it 'preserves structural tags' do
        subject
        expect(attachment.body).to include('<!DOCTYPE html>')
        expect(attachment.body).to include('<html>')
      end

      it 'sanitises the attachments' do
        subject
        expect(attachment.body).to include('dull')
        expect(attachment.body).not_to include('<script>')
      end

      it 'sanitises an HTML filename despite a misleading MIME type' do
        attachment.update_column(:content_type, 'application/xhtml+xml')
        attachment.replace_file!(
          '<html><body>safe<script>unsafe()</script></body></html>'
        )
        subject
        expect(attachment.body).to include('safe')
        expect(attachment.body).not_to include('<script>', 'unsafe()')
      end

      it 'sanitises a filename that is served as HTML after normalising' do
        attachment.update_columns(filename: 'page.html;',
                                  content_type: 'application/octet-stream')
        attachment.replace_file!(
          '<html><body>safe<script>unsafe()</script></body></html>'
        )
        expect(attachment.display_filename).to eq('page.html')

        subject
        expect(attachment.body).to include('safe')
        expect(attachment.body).not_to include('<script>', 'unsafe()')
      end

      ['page.htm;', 'page.htm%6C'].each do |name|
        it "sanitises #{name}, which is served as HTML" do
          attachment.update_columns(filename: name,
                                    content_type: 'application/octet-stream')
          attachment.replace_file!(
            '<html><body>safe<script>unsafe()</script></body></html>'
          )
          served_as = AlaveteliFileTypes.
            filename_to_mimetype(attachment.display_filename)
          expect(served_as).to eq('text/html')

          subject
          expect(attachment.body).to include('safe')
          expect(attachment.body).not_to include('<script>', 'unsafe()')
        end
      end

      it 'removes a remote image from RTF content declared as HTML' do
        attachment.replace_file!(load_file_fixture('rtf-remote-image.rtf'))

        subject

        expect(Nokogiri::HTML5(attachment.body).css('img')).to be_empty
      end

      it 'keeps local images while removing unsafe image sources' do
        html = '<html><body><img src="//example.com/pixel">' \
               '<img src="data:image/png;base64,AA">' \
               '<img src="local.png"></body></html>'
        attachment.replace_file!(html)

        subject

        images = Nokogiri::HTML5(attachment.body).css('img')
        expect(images.map { |image| image['src'] }).to eq(['local.png'])
      end
    end

    context 'with deeply nested HTML attachment' do
      let(:info_request) do
        FactoryBot.create(:info_request_with_deeply_nested_html_attachment)
      end

      it 'collapses redundant nesting and preserves the content as HTML' do
        subject
        expect(attachment.body).to eq(
          "<!DOCTYPE html><html><head></head><body>" \
          "<div>Deeply nested content</div>\n</body></html>"
        )
      end

      it 'sanitises the attachments' do
        subject
        expect(attachment.body).not_to include('<script>')
      end

      context 'when the parser rejects the nesting as too deep' do
        before do
          allow(Loofah).to receive(:html5_document).
            and_raise(ArgumentError, 'Document tree depth limit exceeded')
        end

        it 'falls back to escaped plain text' do
          subject
          expect(attachment.body).
            to eq('Deeply nested content alert(&#39;x&#39;)')
        end

        it 'sanitises the attachments' do
          subject
          expect(attachment.body).not_to include('<script>')
        end
      end
    end

    it 'censors attachments downloaded directly' do
      info_request.censor_rules.create!(
        text: 'dull', replacement: 'Boy', colour: 'black',
        last_edit_editor: 'unknown', last_edit_comment: 'none'
      )
      subject
      expect(attachment.body).to_not include 'dull'
      expect(attachment.body).to include 'Boy'
    end

    it 'censors with rules on the user (rather than the request)' do
      info_request.user.censor_rules.create!(
        text: 'dull', replacement: 'Mole', colour: 'black',
        last_edit_editor: 'unknown', last_edit_comment: 'none'
      )
      subject
      expect(attachment.body).to_not include 'dull'
      expect(attachment.body).to include 'Mole'
    end

    it 'censors with rules on the public body (rather than the request)' do
      info_request.public_body.censor_rules.create!(
        text: 'dull', replacement: 'Fox', colour: 'black',
        last_edit_editor: 'unknown', last_edit_comment: 'none'
      )
      subject
      expect(attachment.body).to_not include 'dull'
      expect(attachment.body).to include 'Fox'
    end

    it 'censors with rules globally (rather than the request)' do
      CensorRule.create!(
        text: 'dull', replacement: 'Horse', colour: 'black',
        last_edit_editor: 'unknown', last_edit_comment: 'none'
      )
      subject
      expect(attachment.body).to_not include 'dull'
      expect(attachment.body).to include 'Horse'
    end

    context 'when masking times out' do
      let(:attachment) { FactoryBot.create(:body_text, :unmasked) }

      before do
        attachment.replace_file!('body')
        allow(attachment).to receive(:apply_censor_rules).
          and_raise(Regexp::TimeoutError)
      end

      it 'records the fault, and serves the part as it came' do
        expect { subject }.
          to change { attachment.masking_failed_at }.from(nil).to(be_present)
        expect(attachment.masked_at).to be_present
        expect(attachment.file.download).to eq('body')
      end

      it 'tries again when masked again, keeping the first fault time' do
        subject
        first = attachment.masking_failed_at
        expect(attachment).to receive(:apply_censor_rules).
          and_raise(Regexp::TimeoutError)
        attachment.update_column(:masked_at, nil)
        attachment.mask
        expect(attachment.masking_failed_at).to eq(first)
      end
    end

    context 'when a PDF cannot be masked' do
      let(:attachment) { FactoryBot.create(:body_text, :unmasked) }

      before do
        attachment.replace_file!('body')
        allow(attachment).to receive(:apply_censor_rules).
          and_raise(AlaveteliTextMasker::PDFMaskingError, 'qpdf failed')
      end

      it 'records the fault, and serves the part as it came' do
        expect { subject }.
          to change { attachment.masking_failed_at }.from(nil).to(be_present)
        expect(attachment.masked_at).to be_present
        expect(attachment.file.download).to eq('body')
        expect(attachment.masking_error.message).to eq('qpdf failed')
      end
    end
  end

  describe '#mask_later' do
    subject { foi_attachment.mask_later }

    let(:foi_attachment) { FactoryBot.create(:body_text) }

    it 'enqueues the job' do
      expect { subject }.
        to have_enqueued_job(FoiAttachment::MaskJob).with(foi_attachment)
    end
  end

  describe '#mask_siblings' do
    subject { foi_attachment.mask_siblings }

    let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
    let(:incoming_message) { info_request.incoming_messages.first }
    let(:foi_attachment) do
      FactoryBot.create(:body_text, incoming_message: incoming_message)
    end

    context 'with an unmasked sibling' do
      let!(:sibling) do
        FactoryBot.create(
          :body_text, :unmasked, incoming_message: incoming_message
        )
      end

      it 'masks the sibling' do
        expect { subject }.to change { sibling.reload.masked? }.
          from(false).to(true)
      end

      it 'masks it through MaskJob, so a fault notifies' do
        expect(FoiAttachment::MaskJob).to receive(:perform_now).
          with(sibling).and_call_original
        subject
      end
    end

    context 'with a masked sibling' do
      let!(:sibling) do
        FactoryBot.create(:body_text, incoming_message: incoming_message)
      end

      it 'does not re-mask the sibling' do
        expect { subject }.to_not(change { sibling.reload.masked_at })
      end
    end

    context 'with an erased sibling' do
      let!(:sibling) do
        FactoryBot.create(
          :body_text, :erased, :unmasked, incoming_message: incoming_message
        )
      end

      it 'does not mask the sibling' do
        expect { subject }.to_not change { sibling.reload.masked_at }.from(nil)
      end
    end

    context 'when itself is unmasked' do
      let(:foi_attachment) do
        FactoryBot.create(
          :body_text, :unmasked, incoming_message: incoming_message
        )
      end

      it 'does not mask itself' do
        expect { subject }.to_not change { foi_attachment.reload.masked? }.
          from(false)
      end
    end
  end

  describe '#raw_email_erased?' do
    subject { foi_attachment.raw_email_erased? }

    let(:foi_attachment) { FactoryBot.build(:body_text) }

    before do
      allow(foi_attachment).to receive(:raw_email).and_return(raw_email)
    end

    context 'when the raw_email is erased' do
      let(:raw_email) { double(erased?: true) }
      it { is_expected.to eq(true) }
    end

    context 'when the raw_email is not erased' do
      let(:raw_email) { double(erased?: false) }
      it { is_expected.to eq(false) }
    end
  end

  describe '#erased?' do
    subject { foi_attachment.erased? }

    context 'when erased_at is nil' do
      let(:foi_attachment) { FactoryBot.build(:body_text) }
      it { is_expected.to be false }
    end

    context 'when erased_at is present' do
      let(:foi_attachment) { FactoryBot.build(:body_text, :erased) }
      it { is_expected.to be true }
    end
  end

  describe '#ensure_not_erased!' do
    let(:foi_attachment) { FactoryBot.build(:body_text) }

    context 'when not erased' do
      before do
        allow(foi_attachment).to receive(:erased?).and_return(false)
      end

      it 'returns nil' do
        expect(foi_attachment.ensure_not_erased!).to be_nil
      end
    end

    context 'when erased' do
      before do
        allow(foi_attachment).to receive(:erased?).and_return(true)
        allow(foi_attachment).to receive(:id).and_return(123)
      end

      it 'raises ErasedError error' do
        expect { foi_attachment.ensure_not_erased! }.to raise_error(
          FoiAttachment::ErasedError, 'attachment has been erased (ID=123)'
        )
      end
    end
  end

  describe '#destroy' do
    let(:foi_attachment) { FactoryBot.create(:body_text) }

    it 'purges the stored file once' do
      blob = foi_attachment.file.blob

      expect { foi_attachment.destroy }.
        to have_enqueued_job(ActiveStorage::PurgeJob).with(blob).exactly(:once)

      perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
      expect(blob.service.exist?(blob.key)).to eq(false)
    end
  end

  describe '#erase' do
    subject { foi_attachment.erase(editor: editor, reason: reason) }

    let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
    let(:incoming_message) { info_request.incoming_messages.first }

    let(:foi_attachment) do
      FactoryBot.create(
        :body_text,
        filename: 'bob.txt',
        incoming_message: incoming_message
      )
    end

    let(:editor) { FactoryBot.create(:admin_user) }
    let(:reason) { 'Removing PII' }

    it 'purges later' do
      expect { subject }.to have_enqueued_job(ActiveStorage::PurgeJob).at_least(:once)
    end

    it 'removes filename' do
      expect { subject }.to change(foi_attachment, :filename).
        from('bob.txt').to('attachment.txt')
    end

    it 'purges the attached file' do
      subject
      expect(foi_attachment.reload.file).not_to be_attached
    end

    it 'deletes the file from storage' do
      blob = foi_attachment.file.blob

      perform_enqueued_jobs { subject }

      expect(blob.service.exist?(blob.key)).to eq(false)
    end

    context 'when the purge runs in another process' do
      self.use_transactional_tests = false

      after do
        [info_request, info_request.user, info_request.public_body,
         editor].each(&:destroy)
      end

      it 'deletes the file from storage' do
        blob = foi_attachment.file.blob

        # Purge from another connection part way through the erase, once the
        # file has been detached but before anything has been saved
        allow(foi_attachment).to receive(:expire) do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
            end
          end.join
        end

        subject
        perform_enqueued_jobs(only: ActiveStorage::PurgeJob)

        expect(blob.service.exist?(blob.key)).to eq(false)
      end
    end

    it 'touches erased_at' do
      expect { subject }.to change(foi_attachment, :erased_at).from(nil)
      expect(foi_attachment.erased_at).to be_a(Time)
    end

    def erase_attachment_event
      info_request.info_request_events.find_by(event_type: 'erase_attachment')
    end

    it 'logs an event on the associated info_request' do
      expect { subject }.to change { erase_attachment_event }.from(nil)
    end

    # A failed sibling may still be unmasked, so erase it with the raw email.
    it 'erases a sibling whose masking failed with the raw email' do
      failed = FactoryBot.create(
        :pdf_attachment, incoming_message: foi_attachment.incoming_message,
                         masking_failed_at: Time.current
      )

      expect(subject).to eq(true)
      expect(failed.reload).to be_erased
      expect(foi_attachment.raw_email.reload).to be_erased
    end

    it 'expires the associated info_request' do
      expect(foi_attachment.info_request).to receive(:expire)
      subject
    end

    it 'persists changes' do
      subject
      foi_attachment.reload
      expect(foi_attachment.filename).to eq 'attachment.txt'
      expect(foi_attachment.erased_at).to_not be_nil
    end

    it { is_expected.to eq(true) }

    context 'when erased' do
      before { allow(foi_attachment).to receive(:erased?).and_return(true) }

      it 'does not erase attachment again' do
        expect(foi_attachment).to_not receive(:log_event)
        expect(foi_attachment).to_not receive(:save!)
        expect(foi_attachment).to_not receive(:delete_cached_file!)
        expect(foi_attachment.raw_email).to_not receive(:erase)
        expect(foi_attachment.info_request).to_not receive(:expire)
        subject
      end
    end

    context 'when an event cannot be logged' do
      before do
        expect(foi_attachment).to receive(:log_event).and_return(false)
      end

      it 'does not erase the file' do
        subject
        perform_enqueued_jobs
        expect(foi_attachment.reload).not_to be_erased
      end

      it { is_expected.to eq(false) }
    end

    context 'when the file cannot be purged' do
      before do
        expect_any_instance_of(ActiveStorage::Attached::One).
          to receive(:purge_later).and_raise(ActiveStorage::FileNotFoundError)
      end

      it 'does not erase the file' do
        subject
        perform_enqueued_jobs
        expect(foi_attachment.reload).not_to be_erased
      end

      it { is_expected.to eq(false) }
    end

    context 'when the record cannot be touched' do
      before do
        expect(foi_attachment).
          to receive(:touch).and_raise(ActiveRecord::ActiveRecordError)
      end

      it 'does not erase the file' do
        subject
        expect(foi_attachment.reload).not_to be_erased
      end

      it { is_expected.to eq(false) }
    end

    context 'when the info request cannot be expired' do
      before do
        expect(foi_attachment).to receive(:expire).and_raise(StandardError)
      end

      it 'does not erase the file' do
        subject
        expect(foi_attachment.reload).not_to be_erased
      end

      it 'does not delete the file from storage' do
        blob = foi_attachment.file.blob

        perform_enqueued_jobs { subject }

        expect(blob.service.exist?(blob.key)).to eq(true)
      end

      it { is_expected.to eq(false) }
    end

    it 'erases the raw email' do
      subject
      expect(foi_attachment.raw_email.reload).to be_erased
    end

    context 'when the raw email cannot be erased' do
      before do
        allow(foi_attachment.raw_email).to receive(:erase).
          and_raise(RawEmail::UnmaskedAttachmentsError)
      end

      it 'does not erase the attachment' do
        subject
        expect(foi_attachment.reload).not_to be_erased
      end

      it { is_expected.to eq(false) }
    end

    context 'when a sibling attachment is unmasked' do
      let!(:sibling) do
        FactoryBot.create(
          :body_text, :unmasked, incoming_message: incoming_message
        )
      end

      it 'masks the sibling' do
        expect { subject }.to change { sibling.reload.masked? }.
          from(false).to(true)
      end

      it 'erases the attachment' do
        expect { subject }.to change { foi_attachment.reload.erased? }.
          from(false).to(true)
      end

      it 'erases the raw email' do
        subject
        expect(foi_attachment.raw_email.reload).to be_erased
      end
    end
  end

  describe '#erase_later' do
    subject { foi_attachment.erase_later(editor: editor, reason: reason) }

    let(:foi_attachment) { FactoryBot.create(:body_text) }
    let(:editor) { FactoryBot.create(:admin_user) }
    let(:reason) { 'Removing PII' }

    it 'enqueues the job' do
      expect { subject }.
        to have_enqueued_job(FoiAttachment::EraseJob).
        with(foi_attachment, editor: editor, reason: reason)
    end
  end

  describe '#storage_key' do
    let(:foi_attachment) { FactoryBot.create(:foi_attachment) }

    context 'when file is attached' do
      it 'returns the blob key' do
        expect(foi_attachment.file).to be_attached
        storage_key = foi_attachment.storage_key
        expect(storage_key).to eq(foi_attachment.file.blob.key)
      end
    end

    context 'when file is not attached' do
      before do
        allow(foi_attachment).to receive(:file).
          and_return(double(attached?: false))
      end

      it 'returns nil' do
        expect(foi_attachment.storage_key).to be_nil
      end
    end
  end

  describe 'factories' do
    it 'put the attachment in the raw email of its message' do
      foi_attachment = FactoryBot.create(:pdf_attachment)
      expect(foi_attachment.unmasked_body).to eq(foi_attachment.body)
    end
  end

  describe '#sanitise_html' do
    let(:attachment) { FoiAttachment.new }

    it 'strips remote media beacons and srcset while keeping local images' do
      html = '<img src="local.png" srcset="https://evil.test/x.png 2x">' \
             '<img src="https://evil.test/beacon.png">' \
             '<video src="https://evil.test/v.mp4" ' \
             'poster="https://evil.test/p.jpg"></video>' \
             '<audio src="https://evil.test/a.mp3"></audio>' \
             '<a href="https://example.org" ping="https://evil.test/p">ok</a>'
      sanitised = attachment.sanitise_html(html)

      expect(sanitised).to include('src="local.png"')
      expect(sanitised).not_to include('evil.test')
      expect(sanitised).not_to include('srcset')
      expect(sanitised).not_to include('ping=')
    end
  end
end
