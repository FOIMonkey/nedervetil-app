require 'spec_helper'

RSpec.describe Disclosures::DocumentsHelper do
  describe '.outcome' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'gives the request status and its short description' do
      allow(info_request).to receive(:calculate_status).
        and_return('successful')
      description = InfoRequest::State.short_description('successful')
      expect(described_class.outcome(info_request)).
        to eq(['successful', description])
    end

    it 'gives nothing for a status core cannot describe, and logs only the request and error class' do
      allow(info_request).to receive(:calculate_status).
        and_return('synthetic_state')
      allow(Rails.logger).to receive(:error)
      expect(described_class.outcome(info_request)).to eq([nil, nil])
      expect(Rails.logger).to have_received(:error).with(
        'Disclosures::DocumentsHelper#outcome failed for request ' \
        "#{info_request.id}: RuntimeError"
      )
    end

    it 'lets any other error through' do
      allow(info_request).to receive(:calculate_status).
        and_raise(NoMethodError)
      expect { described_class.outcome(info_request) }.
        to raise_error(NoMethodError)
    end
  end

  describe '.document_converted_from_note' do
    def fake_document(filename:, content_type:, format:, metadata:)
      blob = instance_double(ActiveStorage::Blob, metadata: metadata)
      attachment = instance_double(FoiAttachment, file_blob: blob)
      instance_double(
        Disclosures::Document,
        foi_attachment: attachment,
        filename: filename,
        content_type: content_type,
        format: format,
        format_label: Disclosures::Document::FORMAT_LABELS.fetch(
          format, 'Other'
        )
      )
    end

    it 'formats common converted office formats cleanly' do
      cases = [
        ['.doc', 'application/vnd.ms-word', 'report.pdf', 'application/pdf',
         'pdf', 'Word document (.doc), converted to PDF'],
        ['.docx',
         'application/vnd.openxmlformats-officedocument.' \
         'wordprocessingml.document',
         'report.pdf', 'application/pdf', 'pdf',
         'Word document (.docx), converted to PDF'],
        ['.odt', 'application/vnd.oasis.opendocument.text', 'report.pdf',
         'application/pdf', 'pdf',
         'OpenDocument text (.odt), converted to PDF'],
        ['.xls', 'application/vnd.ms-excel', 'budget.pdf', 'application/pdf',
         'pdf', 'Excel spreadsheet (.xls), converted to PDF'],
        ['.xls', 'application/vnd.ms-excel', 'budget.xlsx',
         'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
         'spreadsheet', 'Excel spreadsheet (.xls), converted to XLSX']
      ]

      cases.each do |from_ext, from_type, name, type, format, expected|
        doc = fake_document(
          filename: name,
          content_type: type,
          format: format,
          metadata: { 'converted_from_extension' => from_ext,
                      'converted_from_content_type' => from_type }
        )
        expect(described_class.document_converted_from_note(doc)).
          to eq(expected)
      end
    end

    it 'returns nil when metadata is missing or matches the current format' do
      unchanged = fake_document(
        filename: 'report.pdf',
        content_type: 'application/pdf',
        format: 'pdf',
        metadata: {}
      )
      same = fake_document(
        filename: 'report.pdf',
        content_type: 'application/pdf',
        format: 'pdf',
        metadata: { 'converted_from_extension' => '.pdf',
                    'converted_from_content_type' => 'application/pdf' }
      )
      expect(described_class.document_converted_from_note(unchanged)).to be_nil
      expect(described_class.document_converted_from_note(same)).to be_nil
    end

    it 'falls back cleanly without exposing raw MIME strings' do
      doc = fake_document(
        filename: 'report.pdf',
        content_type: 'application/pdf',
        format: 'pdf',
        metadata: {
          'converted_from_extension' => '.qaz',
          'converted_from_content_type' => 'application/x-vendor-qaz'
        }
      )
      note = described_class.document_converted_from_note(doc)
      expect(note).to eq('File (.qaz), converted to PDF')
      expect(note).not_to include('application/x-vendor-qaz')
    end
  end
end
