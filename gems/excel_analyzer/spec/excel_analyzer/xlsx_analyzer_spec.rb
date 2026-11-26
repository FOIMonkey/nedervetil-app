# frozen_string_literal: true

require "zip"
require "spec_helper"
require_relative "../support/helpers"

RSpec.describe ExcelAnalyzer::XlsxAnalyzer do
  describe ".accept?" do
    subject { ExcelAnalyzer::XlsxAnalyzer.accept?(blob) }

    context "when the blob is an Excel file" do
      let(:content_type) do
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      end

      let(:blob) { fake_blob(content_type: content_type) }
      it { is_expected.to eq true }
    end

    context "when the blob is not an Excel file" do
      let(:blob) { fake_blob(content_type: "text/plain") }
      it { is_expected.to eq false }
    end
  end

  describe "#metadata" do
    around do |example|
      original_callback = ExcelAnalyzer.on_hidden_metadata
      ExcelAnalyzer.on_hidden_metadata = ->(_blob, _metadata) {}
      example.call
      ExcelAnalyzer.on_hidden_metadata = original_callback
    end

    let(:metadata) { ExcelAnalyzer::XlsxAnalyzer.new(blob).metadata }

    context "when the blob is an Excel file with hidden data" do
      let(:blob) do
        fake_blob(io: File.open(File.join(__dir__, "../fixtures/suspect.xlsx")),
                  content_type: ExcelAnalyzer::XlsxAnalyzer::CONTENT_TYPE)
      end

      def repack_xlsx(source_path, dest_path)
        entries = {}
        Zip::File.open(source_path) do |zip|
          zip.each do |entry|
            entries[entry.name] = entry.get_input_stream.read if entry.file?
          end
        end
        yield entries
        Zip::OutputStream.open(dest_path) do |out|
          entries.each do |name, data|
            out.put_next_entry(name)
            out.write(data)
          end
        end
      end

      it "detects data model" do
        Tempfile.create(["data-model", ".xlsx"]) do |copy|
          repack_xlsx(blob.io.path, copy.path) do |entries|
            entries["xl/model/item.data"] = "x"
          end
          expect(ExcelAnalyzer::Metadata.new(copy.path).to_h[:data_model]).
            to eq(1)
        end
      end

      it "detects external links" do
        expect(metadata[:excel][:external_links]).to eq 1
      end

      it "detects hidden columns" do
        expect(metadata[:excel][:hidden_columns]).to eq 2
      end

      it 'caps a declared hidden column range at the Excel sheet limit' do
        Tempfile.create(["huge-col", ".xlsx"]) do |copy|
          repack_xlsx(blob.io.path, copy.path) do |entries|
            original = entries["xl/worksheets/sheet3.xml"]
            updated = original.sub(
              /(<col\b[^>]*hidden="(?:1|true)"[^>]*max=")\d+"/,
              '\12147483647"'
            )
            expect(updated).not_to eq(original)
            entries["xl/worksheets/sheet3.xml"] = updated
          end
          expect(ExcelAnalyzer::Metadata.new(copy.path).to_h[:hidden_columns]).
            to eq(3)
        end
      end

      it "detects hidden rows" do
        expect(metadata[:excel][:hidden_rows]).to eq 2
      end

      it "detects hidden sheets" do
        expect(metadata[:excel][:hidden_sheets]).to eq 1
      end

      it "detects named ranges" do
        expect(metadata[:excel][:named_ranges]).to eq 1
      end

      it "detects pivot cache" do
        expect(metadata[:excel][:pivot_cache]).to eq 1
      end

      it "does not call on_hidden_metadata callback" do
        expect(ExcelAnalyzer.on_hidden_metadata).to receive(:call)
        metadata
      end
    end

    context "when the blob is an Excel file without hidden data" do
      let(:blob) do
        fake_blob(io: File.open(File.join(__dir__, "../fixtures/data.xlsx")),
                  content_type: ExcelAnalyzer::XlsxAnalyzer::CONTENT_TYPE)
      end

      it "does not detect hidden data" do
        expect(metadata[:excel]).to eq(
          data_model: 0,
          external_links: 0,
          hidden_columns: 0,
          hidden_rows: 0,
          hidden_sheets: 0,
          named_ranges: 0,
          pivot_cache: 0
        )
      end

      it "does not call on_hidden_metadata callback" do
        expect(ExcelAnalyzer.on_hidden_metadata).to_not receive(:call)
        metadata
      end
    end

    context "when the blob is not an Excel file" do
      let(:blob) do
        fake_blob(io: File.open(File.join(__dir__, "../fixtures/plain.txt")),
                  content_type: "text/plain")
      end

      it "returns an error metadata" do
        expect(metadata[:excel]).to match(
          error: a_string_including("not a zip")
        )
      end

      it "does call on_hidden_metadata callback" do
        expect(ExcelAnalyzer.on_hidden_metadata).to receive(:call)
        metadata
      end
    end

    context "when a retryable error occurs while scanning" do
      let(:transient_error) { Class.new(StandardError) }
      let(:blob) do
        fake_blob(io: File.open(File.join(__dir__, "../fixtures/data.xlsx")),
                  content_type: ExcelAnalyzer::XlsxAnalyzer::CONTENT_TYPE)
      end

      around do |example|
        previous_errors = ExcelAnalyzer.retryable_errors
        previous_reader = ExcelAnalyzer.metadata_reader
        ExcelAnalyzer.retryable_errors = [transient_error]
        ExcelAnalyzer.metadata_reader = ->(_path) do
          raise transient_error, "cell down"
        end
        example.call
      ensure
        ExcelAnalyzer.retryable_errors = previous_errors
        ExcelAnalyzer.metadata_reader = previous_reader
      end

      it "propagates the error without triggering on_hidden_metadata" do
        expect(ExcelAnalyzer.on_hidden_metadata).not_to receive(:call)
        expect { metadata }.to raise_error(transient_error, "cell down")
      end
    end
  end

  describe 'ExcelAnalyzer.on_hidden_metadata hook' do
    around do |example|
      original_callback = ExcelAnalyzer.on_hidden_metadata
      ExcelAnalyzer.on_hidden_metadata = ->(_blob, _metadata) {}
      example.call
      ExcelAnalyzer.on_hidden_metadata = original_callback
    end

    let(:analyzer) { ExcelAnalyzer::XlsxAnalyzer.new(double) }

    before { allow(analyzer).to receive(:excel_metadata).and_return(metadata) }
    after { analyzer.metadata }

    context 'when metadata contains an error' do
      let(:metadata) { { error: 'Error occurred' } }

      it 'should run' do
        expect(ExcelAnalyzer.on_hidden_metadata).to receive(:call)
      end
    end

    context 'when metadata contains only named_ranges' do
      let(:metadata) { { named_ranges: 1, other: 0 } }

      it 'should not be run' do
        expect(ExcelAnalyzer.on_hidden_metadata).to_not receive(:call)
      end
    end

    context 'when metadata contains only external_links' do
      let(:metadata) { { external_links: 1, other: 0 } }

      it 'should not be run' do
        expect(ExcelAnalyzer.on_hidden_metadata).to_not receive(:call)
      end
    end

    context 'when metadata contains external_links/named_ranges and another criteria' do
      let(:metadata) { { external_links: 1, named_ranges: 1 } }

      it 'should run' do
        expect(ExcelAnalyzer.on_hidden_metadata).to receive(:call)
      end
    end

    context 'when metadata contains anything else' do
      let(:metadata) { { other: 1 } }

      it 'should run' do
        expect(ExcelAnalyzer.on_hidden_metadata).to receive(:call)
      end
    end

    context 'when metadata contains 50 hidden rows only' do
      let(:metadata) { { hidden_rows: 50 } }

      it 'should not be run' do
        expect(ExcelAnalyzer.on_hidden_metadata).to_not receive(:call)
      end
    end

    context 'when metadata contains 50 hidden rows and anything else' do
      let(:metadata) { { hidden_rows: 50, other: 1 } }

      it 'should run' do
        expect(ExcelAnalyzer.on_hidden_metadata).to receive(:call)
      end
    end
  end
end
