# frozen_string_literal: true

require "spec_helper"
require_relative "../support/helpers"

RSpec.describe ExcelAnalyzer::XlsAnalyzer do
  describe ".accept?" do
    subject { ExcelAnalyzer::XlsAnalyzer.accept?(blob) }

    context "when the blob is an Excel file" do
      let(:blob) { fake_blob(content_type: "application/vnd.ms-excel") }
      it { is_expected.to eq true }
    end

    context "when the content type is in another case" do
      let(:blob) { fake_blob(content_type: "application/VND.ms-excel") }
      it { is_expected.to eq true }
    end

    context "when the blob is an Excel binary workbook (.xlsb)" do
      let(:blob) do
        fake_blob(
          content_type: "application/vnd.ms-excel.sheet.binary.macroEnabled.12"
        )
      end

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
    ensure
      ExcelAnalyzer.on_hidden_metadata = original_callback
    end

    let(:metadata) { ExcelAnalyzer::XlsAnalyzer.new(blob).metadata }

    context "when the blob is an Excel file with hidden data" do
      let(:blob) do
        fake_blob(io: File.open(File.join(__dir__, "../fixtures/suspect.xls")),
                  content_type: ExcelAnalyzer::XlsAnalyzer::CONTENT_TYPE)
      end

      it "calls on_hidden_metadata callback" do
        expect(ExcelAnalyzer.on_hidden_metadata).to receive(:call)
        metadata
      end

      it 'propagates a failed hold callback' do
        allow(ExcelAnalyzer.on_hidden_metadata).to receive(:call).
          and_raise('synthetic hold failure')
        expect { metadata }.to raise_error('synthetic hold failure')
      end

      it "does not detect data model" do
        expect(metadata[:excel][:data_model]).to eq 0
      end

      it "detects external links" do
        expect(metadata[:excel][:external_links]).to eq 1
      end

      it "detects hidden columns" do
        expect(metadata[:excel][:hidden_columns]).to eq 2
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
    end

    context "when the blob is an Excel file without hidden data" do
      let(:blob) do
        fake_blob(io: File.open(File.join(__dir__, "../fixtures/data.xls")),
                  content_type: ExcelAnalyzer::XlsAnalyzer::CONTENT_TYPE)
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
    end

    context "when the blob is not an Excel file" do
      let(:blob) do
        fake_blob(io: File.open(File.join(__dir__, "../fixtures/plain.txt")),
                  content_type: "text/plain")
      end

      it "returns an error metadata" do
        expect(metadata[:excel]).to eq(error: "LibreOffice conversion failed")
      end
    end

    context "when a retryable error occurs while converting" do
      let(:transient_error) { Class.new(StandardError) }
      let(:blob) do
        fake_blob(io: File.open(File.join(__dir__, "../fixtures/data.xls")),
                  content_type: ExcelAnalyzer::XlsAnalyzer::CONTENT_TYPE)
      end

      around do |example|
        previous_errors = ExcelAnalyzer.retryable_errors
        ExcelAnalyzer.retryable_errors = [transient_error]
        example.call
      ensure
        ExcelAnalyzer.retryable_errors = previous_errors
      end

      it "propagates the error without triggering on_hidden_metadata" do
        allow_any_instance_of(ExcelAnalyzer::XlsAnalyzer).
          to receive(:convert).and_raise(transient_error, "cell down")
        expect(ExcelAnalyzer.on_hidden_metadata).not_to receive(:call)
        expect { metadata }.to raise_error(transient_error, "cell down")
      end
    end
  end
end
