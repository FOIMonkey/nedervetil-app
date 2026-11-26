require 'spec_helper'
require 'tempfile'

RSpec.describe Disclosures::HiddenRisk do
  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:document) do
    instance_double(Disclosures::Document, info_request: info_request,
                                           requester: owner)
  end

  def item(texts, readable: true, type: 'hidden_sheet', name: 'Staff')
    OfficePackage::Hidden::Item.new(type: type, name: name, texts: texts,
                                    readable: readable, count: 1)
  end

  it 'weighs a few harmless values low' do
    harmless = item(%w[Total 12 North], type: 'hidden_rows')
    expect(described_class.level(harmless, document)).to eq(:low)
    expect(described_class.level(item([], type: 'hidden_columns'), document)).
      to eq(:low)
  end

  it 'weighs many different values high, and many copies of one low' do
    names = (1..50).map { |n| "Person #{n}" }
    expect(described_class.high?(names, document)).to be(true)
    expect(described_class.high?(names.first(49), document)).to be(false)
    expect(described_class.high?(['Yes'] * 500, document)).to be(false)
  end

  it 'weighs personal data high' do
    [['jane.example@example.org'], ['jane.doe@gov.wales'], ['foi@llyw.cymru'],
     ['Notes from Rowan Requester']].
      each do |texts|
        expect(described_class.high?(texts, document)).to be(true), texts.first
      end
  end

  it 'keeps cell order for the requester’s name when a short surname repeats' do
    short = FactoryBot.create(:user, name: 'Rowan Lee')
    short_request = FactoryBot.create(:info_request, user: short)
    short_document = instance_double(Disclosures::Document,
                                     info_request: short_request,
                                     requester: short)
    expect(described_class.high?(%w[Ann Lee Rowan Lee], short_document)).
      to be(true)
  end

  it 'leaves phone, NI and NHS numbers to the PII check, as patterns match too much else' do
    expect(described_class.high?(['01632 960123', 'AB 12 34 56 C',
                                  '943 476 5919'], document)).to be(false)
  end

  it 'weighs every hidden sheet high, whatever it holds' do
    expect(described_class.level(item(%w[Yes No]), document)).to eq(:high)
    expect(described_class.level(item([], type: 'very_hidden_sheet'),
                                 document)).to eq(:high)
    expect(described_class.level(item(%w[Yes No], type: 'hidden_rows'),
                                 document)).to eq(:low)
  end

  describe 'named ranges and links to other workbooks' do
    let(:r) { OfficeFixtures::R }

    def findings(cells, names: true, links: true)
      rels = []
      parts = {}
      if links
        rels << ['rIdL', "#{r}externalLink", 'externalLinks/externalLink1.xml']
        parts['xl/externalLinks/externalLink1.xml'] =
          ["#{OfficeFixtures::CT}spreadsheetml.externalLink+xml",
           '<externalLink/>']
      end
      extra = if names
                '<definedNames><definedName name="Staff">Sheet1!$A$1' \
                '</definedName></definedNames>'
              else
                ''
              end
      bytes = OfficeFixtures.workbook(
        sheets: {
          'xl/worksheets/sheet1.xml' => OfficeFixtures.sheet_xml(cells)
        },
        core: nil, workbook_rels: rels, parts: parts, workbook_extra: extra
      )
      Tempfile.create(%w[book .xlsx]) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        described_class.findings(file.path, document).
          to_h { |finding| [finding.label, finding.level] }
      end
    end

    it 'lists them, as high, only when a file has both and looks personal' do
      personal = [['Contact', 'jane.example@example.org']]
      expect(findings(personal)).to eq('1 named range' => :high,
                                       'Links to other workbooks' => :high)
      expect(findings([%w[Depot Vans]])).to eq({})
      expect(findings(personal, links: false)).to eq({})
      expect(findings(personal, names: false)).to eq({})
    end

    it 'keeps cell order for the requester’s name in paired workbook checks' do
      owner.update!(name: 'Rowan Lee')
      expect(findings([%w[Ann Lee], %w[Rowan Lee]])).
        to eq('1 named range' => :high,
              'Links to other workbooks' => :high)
    end
  end

  describe 'with the PII check switched on' do
    before do
      allow(AlaveteliConfiguration).to receive(:disclosures_pii_check).
        and_return('presidio')
      allow(AlaveteliConfiguration).
        to receive(:disclosures_pii_check_endpoint).
        and_return('http://127.0.0.1:5002')
    end

    def presidio(body, status: 200)
      stub_request(:post, 'http://127.0.0.1:5002/analyze').
        to_return(status: status, body: body.to_json,
                  headers: { 'Content-Type' => 'application/json' })
    end

    it 'weighs high what it finds names in' do
      presidio([{ entity_type: 'PERSON', score: 0.85, start: 4, end: 16 }])
      expect(
        described_class.high?(['Ask Anjali Raval about leave'], document)
      ).to be(true)
    end

    it 'weighs low what it clears' do
      presidio([])
      expect(described_class.high?(['Depot totals'], document)).to be(false)
    end

    it 'weighs high what it can’t check' do
      presidio({}, status: 503)
      expect(described_class.high?(['Depot totals'], document)).to be(true)
    end

    it 'checks the file of a requester who opted out of AI reading like anyone’s' do
      skip 'IncomingAttention::OptOut arrives in B10' unless defined?(IncomingAttention::OptOut)

      request = presidio([])
      IncomingAttention::OptOut.set!(owner, true)
      expect(described_class.high?(['Depot totals'], document)).to be(false)
      expect(request).to have_been_requested
    end

    it 'sends each distinct hidden cell once' do
      request = stub_request(:post, 'http://127.0.0.1:5002/analyze').
                with(body: hash_including('text' => "Finance\nHR")).
                to_return(status: 200, body: [].to_json,
                          headers: { 'Content-Type' => 'application/json' })
      cells = (['Finance', ' HR ', 'Finance', ''] * 20)
      expect(described_class.high?(cells, document)).to be(false)
      expect(request).to have_been_requested
    end
  end

  it 'weighs a censor rule’s match high' do
    FactoryBot.create(:info_request_censor_rule, censorable: info_request,
                                                 text: 'Project Zebra')
    expect(described_class.high?(['About Project Zebra'],
                                 info_request.reload && document)).
      to be(true)
  end

  it 'weighs what it can’t read high' do
    expect(described_class.level(item([], readable: false), document)).
      to eq(:high)
  end

  it 'lists a title only when it names the requester' do
    allow(OfficePackage::Hidden).to receive(:call).and_return(
      [item(['Fleet report'], type: 'title')]
    )
    expect(described_class.findings(__FILE__, document)).to be_empty
    allow(OfficePackage::Hidden).to receive(:call).and_return(
      [item(['Letter to Rowan Requester'], type: 'title')]
    )
    expect(described_class.findings(__FILE__, document).map(&:label)).
      to eq(['Title in document properties: Letter to Rowan Requester'])
  end

  it 'labels with the file’s own words as plain text, for the page to escape once' do
    label = described_class.label(item(['x'], name: 'R&D <staff>'))
    expect(label).to eq('Hidden sheet: R&D <staff>')
    expect(label).not_to be_html_safe
    unread = described_class.label(item([], readable: false,
                                            type: 'data_model'))
    expect(unread).to eq('A data model (this site can’t read what’s in it)')
  end
end
