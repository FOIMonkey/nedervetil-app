# frozen_string_literal: true

require "spec_helper"
require_relative "../support/helpers"

RSpec.describe ExcelAnalyzer::EmlAnalyzer do
  describe ".accept?" do
    subject { ExcelAnalyzer::EmlAnalyzer.accept?(blob) }

    context "when the blob is an email" do
      let(:blob) { fake_blob(content_type: "message/rfc822") }
      it { is_expected.to eq true }
    end

    context "when the blob is not an email" do
      let(:blob) { fake_blob(content_type: "text/plain") }
      it { is_expected.to eq false }
    end
  end

  describe "#metadata" do
    around do |example|
      original_callback = ExcelAnalyzer.on_spreadsheet_received
      ExcelAnalyzer.on_spreadsheet_received = ->(blob) {}
      example.call
      ExcelAnalyzer.on_spreadsheet_received = original_callback
    end

    let(:mail) do
      Mail.new { add_file File.join(__dir__, "../fixtures/plain.txt") }
    end

    let(:io) { double(:File, path: "blob/path") }
    let(:blob) { fake_blob(io: io, content_type: "message/rfc822") }

    subject(:metadata) { ExcelAnalyzer::EmlAnalyzer.new(blob).metadata }

    # The mail is read in this process: the app's sandbox, which could send
    # the read elsewhere, is not part of this gem.
    before do
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with("blob/path").
        and_return(mail.to_s)
      stub_const("AlaveteliSandbox", double(required?: false))
    end

    it { is_expected.to eq({}) }

    context "when mail contains XLS attachment" do
      let(:mail) do
        Mail.new { add_file File.join(__dir__, "../fixtures/data.xls") }
      end

      it { is_expected.to eq({}) }

      it "calls on_spreadsheet_received callback" do
        expect(ExcelAnalyzer.on_spreadsheet_received).
          to receive(:call).with(blob)
        metadata
      end
    end

    context "when mail contains XLSX attachment" do
      let(:mail) do
        Mail.new { add_file File.join(__dir__, "../fixtures/data.xlsx") }
      end

      it { is_expected.to eq({}) }
      it "calls on_spreadsheet_received callback" do
        expect(ExcelAnalyzer.on_spreadsheet_received).
          to receive(:call).with(blob)
        metadata
      end
    end

    context "when mail contains XLS and XLSX attachment" do
      let(:mail) do
        Mail.new do
          add_file File.join(__dir__, "../fixtures/data.xls")
          add_file File.join(__dir__, "../fixtures/data.xlsx")
        end
      end

      it { is_expected.to eq({}) }
      it "calls on_spreadsheet_received callback once only" do
        expect(ExcelAnalyzer.on_spreadsheet_received).
          to receive(:call).with(blob).once
        metadata
      end
    end

    context "when mail contains a generic OLE Office attachment" do
      let(:mail) do
        Mail.new do
          attachments["locked.docx"] = {
            mime_type: "application/x-ole-storage",
            content: "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b
          }
        end
      end

      it "calls on_spreadsheet_received callback" do
        expect(ExcelAnalyzer.on_spreadsheet_received).
          to receive(:call).with(blob)
        metadata
      end
    end

    context "when mail contains a generic OLE non-Office attachment" do
      let(:mail) do
        Mail.new do
          attachments["note.msg"] = {
            mime_type: "application/x-ole-storage",
            content: "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b
          }
        end
      end

      it "does not call on_spreadsheet_received callback" do
        expect(ExcelAnalyzer.on_spreadsheet_received).not_to receive(:call)
        metadata
      end
    end
  end
end
