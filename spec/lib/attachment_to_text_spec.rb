require 'spec_helper'

RSpec.describe AttachmentToText do
  describe 'caller contract' do
    it 'extracts the supplied default body without reading the original body' do
      attachment = instance_double(FoiAttachment, content_type: 'text/plain',
                                                  default_body: '[redacted]')
      expect(attachment).not_to receive(:unmasked_body)

      expect(described_class.new(attachment).to_text).to eq("[redacted]\n\n")
    end

    it 'keeps the default MIME type and UTF-8 output of from_string' do
      text = described_class.from_string('Räksmörgås').to_text

      expect(text).to eq("Räksmörgås\n\n")
      expect(text.encoding).to eq(Encoding::UTF_8)
    end

    it 'uses the text argument and MIME type supplied to from_part' do
      part = Mail::Part.new(content_type: 'text/html', body: 'original secret')
      text = described_class.from_part(part, '<p>Reviewed text</p>').to_text

      expect(text).to include('Reviewed text')
      expect(text).not_to include('original secret', '<p>')
    end

    %w[text/html application/pdf].each do |content_type|
      it "raises a named retryable failure for #{content_type}" do
        allow(AlaveteliSandbox).to receive(:job).
          and_raise(AlaveteliSandbox::Refused, 'disabled')

        # Retryable so MainBody does not permanently cache a transient failure.
        expect {
          described_class.from_string('private bytes',
                                      content_type: content_type).to_text
        }.to raise_error(AttachmentToText::ConversionFailed)
      end
    end

    it 'raises the named failure for a PDF with the OCR threshold set' do
      allow(AlaveteliSandbox).to receive(:job).
        and_raise(AlaveteliSandbox::Refused, 'disabled')
      original = described_class.pdf_ocr_threshold
      described_class.pdf_ocr_threshold = 1000

      # Must raise before the OCR threshold checks nil text length.
      expect {
        described_class.from_string('private bytes',
                                    content_type: 'application/pdf').to_text
      }.to raise_error(AttachmentToText::ConversionFailed)
    ensure
      described_class.pdf_ocr_threshold = original
    end

    %w[
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
      application/vnd.openxmlformats-officedocument.presentationml.presentation
    ].each do |content_type|
      it "keeps permanent empty text for #{content_type} on failure" do
        allow(AlaveteliSandbox).to receive(:job).
          and_raise(AlaveteliSandbox::Refused, 'disabled')

        # Zip-based Office text is display/search only; cache empty text on
        # failure rather than retrying on every view.
        expect(
          described_class.from_string('private bytes',
                                      content_type: content_type).to_text
        ).to eq('')
      end
    end
  end

  describe '#to_text' do
    subject { described_class.new(attachment).to_text }

    # Currently handled
    # --------------------------------------------------------------------------

    context 'doc' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/vnd.ms-word',
          body: load_file_fixture('lorem.doc')
        )
      end
      it { is_expected.to match(/lorem/) }
    end

    context 'docx' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/vnd.openxmlformats-officedocument.' \
            'wordprocessingml.document',
          body: load_file_fixture('lorem.docx')
        )
      end
      it { is_expected.to match(/lorem/) }
    end

    context 'html' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'text/html',
          body: load_file_fixture('interesting.html')
        )
      end

      it { is_expected.to match(/dull/) }

      context 'with UTF-8 characters' do
        let(:attachment) do
          FoiAttachment.new(
            content_type: 'text/html',
            body: '<html><b>foo</b> është'
          )
        end

        it 'retains the UTF-8 characters in the extracted text' do
          is_expected.to match(/është/)
        end
      end
    end

    context 'pdf' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/pdf',
          body: load_file_fixture('interesting.pdf')
        )
      end
      it { is_expected.to match(/thisisthebody/) }

      context 'when pdf_ocr_threshold is not set' do
        let(:instance) { described_class.new(attachment) }

        before { described_class.pdf_ocr_threshold = nil }

        it 'does not fall back to OCR even when extracted text is empty' do
          allow(instance).to receive(:extract_text_pdf).and_return('')
          expect(instance).not_to receive(:ocr_pdf)
          instance.to_text
        end
      end

      context 'when pdf_ocr_threshold is set' do
        let(:instance) { described_class.new(attachment) }

        around do |example|
          described_class.pdf_ocr_threshold = 100
          example.run
        ensure
          described_class.pdf_ocr_threshold = nil
        end

        context 'when the extracted text length meets the threshold' do
          before do
            allow(instance).to receive(:extract_text_pdf).and_return('a' * 200)
          end

          it 'returns the pdftotext result without OCR' do
            expect(instance).not_to receive(:ocr_pdf)
            instance.to_text
          end
        end

        context 'when the extracted text length is below the threshold' do
          before do
            allow(instance).to receive(:extract_text_pdf).and_return('short')
          end

          it 'falls back to OCR' do
            expect(instance).to receive(:ocr_pdf).and_return('')
            instance.to_text
          end
        end
      end
    end

    context 'ppt' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/vnd.ms-powerpoint',
          body: load_file_fixture('interesting.ppt')
        )
      end

      it 'includes contents from the first slide' do
        is_expected.to match(/Interesting/)
      end

      it 'includes contents from subsequent slides' do
        is_expected.to match(/Lorem/)
      end
    end

    context 'pptx' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/vnd.openxmlformats-officedocument.' \
            'presentationml.presentation',
          body: load_file_fixture('interesting.pptx')
        )
      end

      it 'includes contents from the first slide' do
        is_expected.to match(/Interesting/)
      end

      it 'includes contents from subsequent slides' do
        is_expected.to match(/Lorem/)
      end
    end

    context 'rtf' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/rtf',
          body: load_file_fixture('interesting.rtf')
        )
      end
      it { is_expected.to match(/thisisthebody/) }

      context 'when LibreOffice writes no output' do
        before do
          allow_any_instance_of(AlaveteliSandbox::Job).to receive(:run)
        end

        it { is_expected.to eq('') }
      end

      context 'when LibreOffice fails' do
        before do
          allow_any_instance_of(AlaveteliSandbox::Job).
            to receive(:run).and_raise(AlaveteliSandbox::Failed, 'exit 1')
        end

        it { is_expected.to eq('') }
      end
    end

    context 'txt' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'text/plain',
          body: 'hereisthetext'
        )
      end
      it { is_expected.to match(/hereisthetext/) }
    end

    context 'xls' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/vnd.ms-excel',
          body: load_file_fixture('interesting.xls')
        )
      end

      it 'includes the first sheet name' do
        is_expected.to match(/Sheet1/)
      end

      it 'includes the first sheet contents' do
        is_expected.to match(/foo/)
      end

      it 'includes subsequent sheet names' do
        is_expected.to match(/Sheet2/)
      end

      it 'includes subsequent sheet contents' do
        is_expected.to match(/baz/)
      end
    end

    context 'xlsx' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/vnd.openxmlformats-officedocument.' \
            'spreadsheetml.sheet',
          body: body
        )
      end
      let(:body) { load_file_fixture('interesting.xlsx') }

      it 'includes the first sheet name' do
        is_expected.to match(/Sheet1/)
      end

      it 'includes the first sheet contents' do
        is_expected.to match(/foo/)
      end

      it 'includes subsequent sheet names' do
        is_expected.to match(/Sheet2/)
      end

      it 'includes subsequent sheet contents' do
        is_expected.to match(/baz/)
      end

      context 'with a sparsely populated spreadsheet' do
        let(:body) { load_file_fixture('sparse.xlsx') }

        it 'extracts the substantive contents' do
          is_expected.to match(/cat/)
        end

        it 'squeezes repetitive commas' do
          is_expected.not_to match(/,,/)
        end
      end

      it 'stops combining CSV sheets once cumulative MAX_TEXT is reached' do
        stub_const('AttachmentToText::MAX_TEXT', 60)
        extractor = described_class.new(attachment)
        AlaveteliSandbox.job do |job|
          File.write(job.scratch("#{AttachmentToText::INPUT_NAME}-S1.csv"),
                     'a' * 30)
          File.write(job.scratch("#{AttachmentToText::INPUT_NAME}-S2.csv"),
                     'b' * 30)
          combined = extractor.send(:combine_csv_files_with_sheet_names, job)
          expect(combined).to include('=== S1 ===', 'a' * 30)
          expect(combined).not_to include('=== S2 ===')
          expect(combined.bytesize).to be <= 60
        end
      end
    end

    context 'csv' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'text/csv',
          body: load_file_fixture('interesting.csv')
        )
      end
      it { is_expected.to match(/foo/) }
      it { is_expected.to match(/maçã/) }
    end

    context 'zip' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'application/zip',
          body: load_file_fixture('example.zip')
        )
      end

      it { is_expected.to match(/Contravention/) }

      it 'stops extracting inside a third nested archive' do
        innermost = OfficeFixtures.package({ 'secret.txt' => 'deep secret' })
        middle = OfficeFixtures.package({ 'inner.zip' => innermost })
        outer = OfficeFixtures.package({ 'middle.zip' => middle,
                                         'visible.txt' => 'visible text' })
        text = described_class.from_string(
          outer, content_type: 'application/zip'
        ).to_text
        expect(text).to include('visible text')
        expect(text).not_to include('deep secret')
      end

      it 'reads zip archives through OfficePackage::Isolated' do
        archive = OfficeFixtures.package({ 'note.txt' => 'sandboxed text' })
        expect(OfficePackage::Isolated).to receive(:read_zip).and_call_original

        text = described_class.from_string(
          archive, content_type: 'application/zip'
        ).to_text
        expect(text).to include('sandboxed text')
      end

      it 'propagates AlaveteliSandbox::Error when the Office cell is down' do
        archive = OfficeFixtures.package({ 'note.txt' => 'sandboxed text' })
        allow(OfficePackage::Isolated).to receive(:read_zip).
          and_raise(AlaveteliSandbox::Refused, 'office cell unavailable')

        expect {
          described_class.from_string(
            archive, content_type: 'application/zip'
          ).to_text
        }.to raise_error(AlaveteliSandbox::Refused)
      end

      it 'keeps extracting smaller later text files after a nested zip ' \
         'leaves an intermediate entry over the remaining byte budget' do
        inner = OfficeFixtures.package({ 'inside.txt' => 'a' * 200 })
        stub_const('AttachmentToText::MAX_ZIP_TOTAL', inner.bytesize + 250)
        outer = OfficeFixtures.package(
          { '01-inner.zip' => inner,
            '02-large.bin' => 'b' * 245,
            '03-later.txt' => 'later text' }
        )

        text = described_class.from_string(
          outer, content_type: 'application/zip'
        ).to_text
        expect(text).to include('later text')

        problem = AlaveteliSandbox.volume_problem
        next if problem

        allow(AlaveteliConfiguration).to receive(:sandbox_converters).
          and_return('required')
        sandboxed = described_class.from_string(
          outer, content_type: 'application/zip'
        ).to_text
        expect(sandboxed).to include('later text')
      end

      it 'does not inflate an entry larger than its limit' do
        mock_entry = double('Zip::Entry',
                            file?: true,
                            size: described_class::MAX_ZIP_ENTRY + 1)
        expect(mock_entry).not_to receive(:get_input_stream)
        allow(Zip::File).to receive(:open) do |*_args, &block|
          block.call([mock_entry])
        end
        is_expected.to be_empty
      end

      context 'when the expansion of the zip raises an error' do
        before do
          mock_entry = double('Zip::File entry', file?: true, size: 1)

          allow(mock_entry).
            to receive(:get_input_stream).
            and_raise('invalid distance too far back')

          allow(Zip::File).to receive(:open) do |*_args, &block|
            block.call([mock_entry])
          end
        end

        it { is_expected.to be_empty }
      end
    end

    # Unhandled and unlikely to be
    # --------------------------------------------------------------------------

    context 'jpeg' do
      let(:attachment) do
        FoiAttachment.new(
          content_type: 'image/jpeg',
          body: 'someimage'
        )
      end
      it { is_expected.to be_empty }
    end
  end
end
