require 'spec_helper'

RSpec.describe EmailTables do
  def converted_html(html)
    described_class.html_to_text(html) { |input| input }
  end

  def formatted(text)
    described_class.format(CGI.escapeHTML(text)) do |body|
      ActionController::Base.helpers.simple_format(body)
    end
  end

  describe '.html_to_text' do
    it 'adds a border to a data table, including a two-column numeric table' do
      html = '<table><tr><th>Year</th><th>Total</th></tr>' \
             '<tr><td>2025</td><td>1,234</td></tr></table>'

      expect(Nokogiri::HTML5(converted_html(html)).at_css('table')['border']).
        to eq('1')
    end

    it 'does not change HTML without a data table' do
      html = '<p>Before &amp; after</p><table><tr><td>Name</td>' \
             '<td>Department</td></tr><tr><td>Alice</td>' \
             '<td>Finance</td></tr></table>'

      expect(converted_html(html)).to eq(html)
    end

    it 'skips signature and quoted-header layout tables' do
      signature = '<table><tr><td>Name</td><td>Alice</td></tr>' \
                  '<tr><td>Role</td><td>Officer</td></tr></table>'
      quoted_header = '<table><tr><td>To:</td><td>Officer</td></tr>' \
                      '<tr><td>Subject:</td><td>Request</td></tr></table>'

      expect(converted_html(signature)).to eq(signature)
      expect(converted_html(quoted_header)).to eq(quoted_header)
    end

    it 'only marks the innermost data table' do
      html = '<table><tr><td>Layout<table><tr><td>A</td><td>B</td>' \
             '<td>C</td></tr><tr><td>1</td><td>2</td><td>3</td>' \
             '</tr></table></td></tr><tr><td>Footer</td></tr></table>'
      result = Nokogiri::HTML5(converted_html(html))

      expect(result.css('table').map { |table| table['border'] }).
        to eq([nil, '1'])
    end

    it 'skips tables whose cells exceed the length limit' do
      html = "<table><tr><td>#{'x' * 251}</td><td>B</td><td>C</td></tr>" \
             '<tr><td>D</td><td>E</td><td>F</td></tr></table>'

      expect(converted_html(html)).to eq(html)
    end

    it 'stops inspecting a table after the cell cap' do
      row = '<tr>' + ('<td>A</td>' * 21) + '</tr>'
      html = "<table>#{row * 100}</table>"

      expect(converted_html(html)).to eq(html)
    end
    it 'caps the number of cells created by spans' do
      first_row = '<tr>' +
                  ('<td rowspan="50" colspan="50">1</td>' * 5) + '</tr>'
      html = "<table>#{first_row}#{'<tr></tr>' * 49}</table>"

      expect(converted_html(html)).to eq(html)
    end
  end

  it 'renders an Outlook HTML table through elinks as an aligned pre block' do
    path = Rails.root.join('spec/fixtures/files/email_tables_outlook.html')
    source = File.read(path)
    text = described_class.html_to_text(source) do |html|
      AttachmentToText.from_string(html, content_type: 'text/html').to_text
    end
    text = described_class.squeeze_spaces(text)
    html = formatted(text)
    pre = Nokogiri::HTML5.fragment(html).at_css('.correspondence_table pre')

    expect(pre).not_to be_nil
    expect(pre.text).to include('Region', 'North', '1,200')
    expect(pre.text.lines.map { |line| line.chomp.length }.uniq.size).to eq(1)
    expect(html).to include('correspondence_table__scroll')
  end

  describe '.squeeze_spaces' do
    it 'preserves spacing only on lines beginning with box characters' do
      text = "Before   text\n┌───┐\n│A   B│\n└───┘\nAfter   text"

      expect(described_class.squeeze_spaces(text)).
        to eq("Before text\n┌───┐\n│A   B│\n└───┘\nAfter text")
    end
  end

  describe '.format' do
    it 'renders an Outlook-style box fixture in an aligned pre block' do
      path = Rails.root.join('spec/fixtures/files/email_tables_outlook.txt')
      text = File.read(path)
      html = formatted(text)
      pre = Nokogiri::HTML5.fragment(html).at_css('.correspondence_table pre')

      expect(pre).not_to be_nil
      expect(pre.text.lines.map { |line| line.chomp.length }.uniq).to eq([36])
      expect(pre.text).to include('│    North     │  1,200   │  2025  │')
      expect(html).to include('correspondence_table__scroll')
      expect(html).to include('<p>Summary follows.')
    end

    it 'keeps cell scripts and literal HTML entities escaped' do
      source = '<table><tr><td>Name</td><td>Markup</td><td>Value</td>' \
               '</tr><tr><td>Example</td><td>&lt;script&gt;</td>' \
               '<td>&amp;lt;</td></tr></table>'
      text = described_class.html_to_text(source) do |body|
        AttachmentToText.from_string(body, content_type: 'text/html').to_text
      end
      html = formatted(described_class.squeeze_spaces(text))

      expect(html).to include('&lt;script&gt;')
      expect(html).to include('&amp;lt;')
      expect(html).not_to include('<script>')
    end

    it 'preserves ordinary plain text that uses box characters' do
      text = "A sketch:\n┌─────┐\n│ Hi  │\n└─────┘"
      html = formatted(text)

      expect(html).to include('<p>A sketch:</p>')
      expect(html).to include('<pre>┌─────┐')
      expect(html).to include('│ Hi  │')
    end

    it 'leaves the literal prototype placeholder word alone' do
      text = "EMAILTABLEPLACEHOLDER0\n\n┌──┐\n│1 │\n└──┘"
      html = formatted(text)

      expect(html).to include('<p>EMAILTABLEPLACEHOLDER0</p>')
      expect(html).to include('<pre>┌──┐')
    end

    it 'leaves a generated placeholder alone if its block is missing' do
      allow(SecureRandom).to receive(:hex).and_return('known')
      text = "┌──┐\n│1 │\n└──┘"
      html = described_class.format(CGI.escapeHTML(text)) do |body|
        '<p>EMAILTABLEknown99</p>' +
          ActionController::Base.helpers.simple_format(body)
      end

      expect(html).to include('<p>EMAILTABLEknown99</p>')
      expect(html).to include('<pre>┌──┐')
    end

    it 'matches the existing formatter when the email has no box lines' do
      text = CGI.escapeHTML('Hello <world>')
      old = ActionController::Base.helpers.simple_format(text)
      new = described_class.format(text) do |body|
        ActionController::Base.helpers.simple_format(body)
      end

      expect(new).to eq(old)
    end
  end
end
