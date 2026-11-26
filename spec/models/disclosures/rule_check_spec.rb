require 'spec_helper'

RSpec.describe Disclosures::RuleCheck do
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Road contracts')
  end
  let(:xlsx_type) { Disclosures::Formats::SPREADSHEET['.xlsx'] }
  let(:book) do
    OfficeFixtures.workbook(
      sheets: {
        'xl/worksheets/sheet1.xml' =>
          OfficeFixtures.sheet_xml([%w[Contract Value],
                                    %w[Resurfacing 120000]]),
        'xl/worksheets/sheet2.xml' =>
          OfficeFixtures.sheet_xml([['Zebra Contractor Ltd', 'preferred']])
      },
      states: { 2 => 'hidden' },
      core: nil
    )
  end

  def make_document(bytes = book)
    delivered_document(info_request, 'contracts.xlsx', xlsx_type, bytes,
                       by: owner)
  end

  def rule(text)
    FactoryBot.create(:info_request_censor_rule, censorable: info_request,
                                                 text: text)
  end

  it 'matches a rule inside hidden parts of an Office workbook' do
    document = make_document
    rule('Zebra Contractor')
    expect(described_class.match?(document.reload, book)).to be(true)
    expect(described_class.found?(document, book, format: 'spreadsheet')).
      to be(true)
  end

  it 'leaves default masks alone when no censor rule matches' do
    clean_book = OfficeFixtures.workbook(
      sheets: {
        'xl/worksheets/sheet1.xml' =>
          OfficeFixtures.sheet_xml([['Contact', 'roads@example.org']])
      },
      core: nil
    )
    document = make_document(clean_book)
    expect(described_class.match?(document, clean_book)).to be(false)
  end

  it 'can’t read a broken file, so reports it unreadable' do
    document = make_document
    rule('Zebra Contractor')
    expect(described_class.match?(document.reload, 'not a zip at all')).
      to be(false)
    expect { described_class.match?(document, "PK\x03\x04broken".b) }.
      to raise_error(described_class::Unreadable)
    expect(described_class.found?(document, "PK\x03\x04broken".b,
                                  format: 'spreadsheet')).to be(true)
  end

  it 'reports an Office file unreadable when the sandbox refuses or times out' do
    document = make_document
    rule('Zebra Contractor')
    [AlaveteliSandbox::Refused.new('office: busy'),
     AlaveteliSandbox::TimedOut.new('office-worker timed out')].each do |error|
      allow(OfficePackage::Isolated).to receive(:read).and_raise(error)
      expect { described_class.match?(document.reload, book) }.
        to raise_error(described_class::Unreadable)
      expect(described_class.found?(document, book, format: 'spreadsheet')).
        to be(true)
    end
  end
end
