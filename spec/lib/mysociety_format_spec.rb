require 'spec_helper'
require_relative '../../vendor/mysociety/rblib/format'

RSpec.describe MySociety::Format do
  describe '.make_clickable' do
    it 'keeps tab-separated links and text outside generated attributes' do
      text = "www.example.org/path\tname@example.net\tmemo"

      expect(described_class.make_clickable(text)).to eq(
        '<a href="http://www.example.org/path">www.example.org/path</a>' \
        "\t" \
        '<a href="mailto:name@example.net">name@example.net</a>' \
        "\tmemo"
      )
    end

    it 'does not split an HTML entity when shortening a link label' do
      url = "http://example.org/#{'a' * 20}&hello"
      output = described_class.make_clickable(CGI.escapeHTML(url), contract: 1)

      expect(output).to eq(
        %(<a href="#{CGI.escapeHTML(url)}">#{CGI.escapeHTML(url[0, 40])}...</a>)
      )
    end
  end

  describe '.simplify_url_part' do
    def slug(text, max_len = nil)
      described_class.simplify_url_part(text, 'request', max_len)
    end

    it 'lowercases and joins words with underscores' do
      expect(slug('Grit bin locations')).to eq('grit_bin_locations')
    end

    it 'drops accents, including the Welsh ones' do
      expect(slug('Ysgol Gymraeg Llanelli ŵ ŷ – Café')).
        to eq('ysgol_gymraeg_llanelli_w_y_cafe')
    end

    it 'spells out letters that have no separate accent' do
      expect(slug('Straße Øresund Æble')).to eq('strasse_oresund_aeble')
    end

    it 'keeps a dash inside a word as a word break' do
      expect(slug('Costs 2019–2020')).to eq('costs_2019_2020')
    end

    it 'drops punctuation and symbols' do
      expect(slug("Spending over £500 (‘all’ contracts) & fees?")).
        to eq('spending_over_500_all_contracts_fees')
    end

    it 'falls back to the default name for text with no Latin letters' do
      expect(slug('Привет мир')).to eq('request')
    end

    it 'falls back to the default name for a number alone' do
      expect(slug('2024')).to eq('request')
    end

    it 'trims to max_len without leaving a trailing underscore' do
      expect(slug('Fly-tipping reports and fines in 2025', 32)).
        to eq('fly_tipping_reports_and_fines_in')
      expect(slug('abc def', 4)).to eq('abc')
    end
  end
end
