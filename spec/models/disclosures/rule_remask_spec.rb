require 'spec_helper'

RSpec.describe Disclosures::RuleRemask do
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request) }

  def rule(colour)
    FactoryBot.create(:censor_rule, censorable: info_request,
                                    colour: colour,
                                    text: 'SecretTerm',
                                    replacement: '[removed]')
  end

  def state_of(attachment)
    attachment.reload
    { prominence: attachment.prominence,
      hidden_because: attachment.prominence_reason.presence,
      black_masked: attachment.black_masked?,
      masking_failed: attachment.masking_failed?,
      file_masked: attachment.file.download.exclude?('SecretTerm') }
  end

  describe '.apply_to_attachment! on a public text file with the rule’s ' \
           'word in it' do
    let(:text) { "Notes mentioning SecretTerm.\n" }
    let(:document) do
      document = delivered_document(info_request, 'notes.txt', 'text/plain',
                                    text)
      publish(document, by: admin)
    end

    # Handed its document, so a stub on the document is on the object the
    # remask works with.
    let(:attachment) do
      FoiAttachment.find(document.foi_attachment_id).tap do |file|
        file.association(:disclosure_document).target = document
      end
    end

    def remask(colour)
      remask_with { rule(colour) }
    end

    # Saves the rule only once the file is public, as an admin would.
    def remask_with
      result = described_class.apply_to_attachment!(attachment, yield)
      document.reload
      state_of(attachment).merge(result: result,
                                 document: document.state,
                                 pages: document.pages.count)
    end

    def masker_leaves_a_part_unmasked
      allow(Disclosures::Masking).to receive(:apply_rules) do |bytes, **named|
        named[:unmasked] << 'embedded.bin'
        bytes
      end
    end

    context 'when masking removes the word' do
      it 'makes the file public again under a black rule' do
        expect(remask('black')).to eq(
          result: :republished, prominence: 'public', hidden_because: nil,
          black_masked: true, masking_failed: false, file_masked: true,
          document: 'published', pages: 1
        )
        expect(document).to be_listed
        expect(document.pages.pluck(:text).join).to include('[removed]')
      end

      it 'makes the file public again under a blue rule' do
        expect(remask('blue')).to eq(
          result: :republished, prominence: 'public', hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: true,
          document: 'published', pages: 1
        )
        expect(document).to be_listed
      end
    end

    context 'when the masker reports a part it could not mask' do
      before { masker_leaves_a_part_unmasked }

      it 'hides the file from its requester under a black rule' do
        expect(remask('black')).to eq(
          result: :left_private, prominence: 'hidden',
          hidden_because: 'A masking rule failed on this file.',
          black_masked: true, masking_failed: true, file_masked: false,
          document: 'withdrawn', pages: 0
        )
      end

      it 'leaves the file with its requester under a blue rule' do
        expect(remask('blue')).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: false,
          document: 'withdrawn', pages: 0
        )
      end
    end

    context 'when the masker raises' do
      it 'hides the file from its requester under a black rule' do
        allow(Disclosures::Masking).to receive(:apply_rules).
          and_raise(Regexp::TimeoutError)

        expect(remask('black')).to eq(
          result: :left_private, prominence: 'hidden',
          hidden_because: 'A masking rule failed on this file.',
          black_masked: true, masking_failed: true, file_masked: false,
          document: 'withdrawn', pages: 0
        )
      end

      it 'leaves the file with its requester under a blue rule' do
        allow(Disclosures::Masking).to receive(:apply_rules).
          and_raise(AlaveteliTextMasker::PDFMaskingError)

        expect(remask('blue')).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: false,
          document: 'withdrawn', pages: 0
        )
      end
    end

    context 'when the word is still found in the masked file' do
      before do
        allow(Disclosures::RuleCheck).to receive(:found?).and_return(true)
      end

      it 'hides the masked file from its requester under a black rule' do
        expect(remask('black')).to eq(
          result: :left_private, prominence: 'hidden',
          hidden_because: 'A masking rule matched this file.',
          black_masked: true, masking_failed: true, file_masked: true,
          document: 'withdrawn', pages: 0
        )
      end

      it 'leaves the masked file with its requester under a blue rule' do
        expect(remask('blue')).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: true,
          document: 'withdrawn', pages: 0
        )
      end
    end

    context 'when the document’s pages cannot be rebuilt' do
      before do
        allow(document).to receive(:rebuild_pages_from_attachment!).
          and_return(false)
      end

      it 'hides the masked file from its requester under a black rule' do
        expect(remask('black')).to eq(
          result: :left_private, prominence: 'hidden',
          hidden_because: 'A masking rule matched this file.',
          black_masked: true, masking_failed: true, file_masked: true,
          document: 'withdrawn', pages: 0
        )
      end

      it 'leaves the masked file with its requester under a blue rule' do
        expect(remask('blue')).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: true,
          document: 'withdrawn', pages: 0
        )
      end
    end

    context 'when the rebuilt pages are not clean' do
      before do
        allow(described_class).to receive(:clean_rebuilt_document?).
          and_return(false)
      end

      it 'removes the pages and hides the file under a black rule' do
        expect(remask('black')).to eq(
          result: :left_private, prominence: 'hidden',
          hidden_because: 'A masking rule matched this file.',
          black_masked: true, masking_failed: true, file_masked: true,
          document: 'withdrawn', pages: 0
        )
      end

      it 'removes the pages and leaves the file with its requester under a ' \
         'blue rule' do
        expect(remask('blue')).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: true,
          document: 'withdrawn', pages: 0
        )
      end
    end

    context 'when a step after masking raises a timeout' do
      before do
        allow(described_class).to receive(:clean_rebuilt_document?).
          and_raise(Regexp::TimeoutError)
      end

      it 'records a masking failure under a black rule and keeps what was ' \
         'already written' do
        expect(remask('black')).to eq(
          result: :left_private, prominence: 'hidden',
          hidden_because: 'A masking rule failed on this file.',
          black_masked: true, masking_failed: true, file_masked: true,
          document: 'withdrawn', pages: 1
        )
      end
    end

    context 'when the word is in the document’s title too' do
      before { document.update_columns(title: 'SecretTerm notes') }

      it 'masks the file and leaves it with its requester under a black ' \
         'rule' do
        expect(remask('black')).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: true, masking_failed: false, file_masked: true,
          document: 'withdrawn', pages: 0
        )
      end

      it 'masks the file and leaves it with its requester under a blue ' \
         'rule' do
        expect(remask('blue')).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: true,
          document: 'withdrawn', pages: 0
        )
      end
    end

    context 'when the word is only in the document’s title' do
      let(:text) { "Notes with nothing to remove.\n" }

      before { document.update_columns(title: 'SecretTerm notes') }

      it 'leaves the file with its requester, unmasked, under a black ' \
         'rule' do
        expect(remask('black')).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: true,
          document: 'withdrawn', pages: 0
        )
        expect(attachment.file.download).to eq(text)
      end
    end

    context 'when a pattern rule runs out of time on the document’s title' do
      let(:text) { "Notes with nothing to remove.\n" }

      before { document.update_columns(title: "#{'a' * 40}!") }

      # The second alternative backtracks without end on a long run of a's.
      def slow_pattern_rule
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        regexp: true,
                                        text: 'SecretTerm|^(a|a)*\1$',
                                        replacement: '[removed]')
      end

      def with_short_regexp_timeout
        timeout = Regexp.timeout
        Regexp.timeout = 0.1
        yield
      ensure
        Regexp.timeout = timeout
      end

      it 'leaves the file with its requester, as when the title holds the ' \
         'rule’s words, and logs the document’s id but not its title' do
        allow(Rails.logger).to receive(:warn)

        state = with_short_regexp_timeout { remask_with { slow_pattern_rule } }

        expect(state).to eq(
          result: :left_private, prominence: 'requester_only',
          hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: true,
          document: 'withdrawn', pages: 0
        )
        expect(Rails.logger).to have_received(:warn).with(
          "rule_remask_details_unreadable document_id=#{document.id} " \
          'Disclosures::RuleCheck::Unreadable'
        )
      end
    end

    context 'when masking changes no bytes and the checks pass' do
      before do
        allow(Disclosures::Masking).to receive(:apply_rules) { |bytes, **| bytes }
        allow(Disclosures::RuleCheck).to receive(:found?).and_return(false)
        allow(described_class).to receive(:clean_rebuilt_document?).
          and_return(true)
      end

      it 'marks the file black-masked without a new masking time' do
        masked_at = attachment.masked_at

        expect(remask('black')).to eq(
          result: :republished, prominence: 'public', hidden_because: nil,
          black_masked: true, masking_failed: false, file_masked: false,
          document: 'published', pages: 1
        )
        expect(attachment.masked_at).to eq(masked_at)
      end

      it 'changes nothing on the file under a blue rule' do
        expect(remask('blue')).to eq(
          result: :republished, prominence: 'public', hidden_because: nil,
          black_masked: false, masking_failed: false, file_masked: false,
          document: 'published', pages: 1
        )
      end
    end
  end

  def public_file_without_a_document(name, type, bytes)
    reply = AttachmentFixtures.deliver(info_request, [[name, type, bytes]])
    file_in(reply, name).tap(&:make_public!)
  end

  describe '.apply_to_attachment! on a public file with no document' do
    let(:attachment) do
      public_file_without_a_document('notes.txt', 'text/plain',
                                     "Notes on SecretTerm.\n")
    end

    it 'masks the file and makes it public again' do
      result = described_class.apply_to_attachment!(attachment, rule('black'))

      expect(result).to eq(:republished)
      expect(state_of(attachment)).to eq(
        prominence: 'public', hidden_because: nil,
        black_masked: true, masking_failed: false, file_masked: true
      )
    end
  end

  describe '.apply_to_attachment! on a public file of a kind that is not ' \
           'masked in place' do
    let(:attachment) do
      public_file_without_a_document('notes.xml', 'application/xml',
                                     "<note>SecretTerm</note>\n")
    end

    it 'masks it as a private file and leaves it with its requester under ' \
       'a black rule' do
      result = described_class.apply_to_attachment!(attachment, rule('black'))

      expect(result).to eq(:left_private)
      expect(state_of(attachment)).to eq(
        prominence: 'requester_only', hidden_because: nil,
        black_masked: true, masking_failed: false, file_masked: true
      )
    end

    it 'leaves it with its requester, unmasked, under a blue rule' do
      result = described_class.apply_to_attachment!(attachment, rule('blue'))

      expect(result).to eq(:left_private)
      expect(state_of(attachment)).to eq(
        prominence: 'requester_only', hidden_because: nil,
        black_masked: false, masking_failed: false, file_masked: false
      )
    end
  end
end
