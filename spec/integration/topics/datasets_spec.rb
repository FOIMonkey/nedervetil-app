require 'spec_helper'

RSpec.describe 'Published datasets' do
  include_context 'with production error pages'

  def page
    Nokogiri::HTML(response.body)
  end

  describe 'the catalogue' do
    it 'refuses a misspelt key, an unknown kind and an area link without a code' do
      row = { 'id' => 'x', 'publisher' => 'X', 'title' => 'X', 'url' => 'https://x', 'kind' => 'table', 'status' => 'open' }
      expect { Topics::Dataset.new(row.merge('urll' => 'https://x')) }.
        to raise_error(ArgumentError, /unknown keys urll/)
      expect { Topics::Dataset.new(row.merge('kind' => 'page')) }.
        to raise_error(ArgumentError, /kind/)
      expect do
        Topics::Dataset.new(row.merge('area_url' => 'https://x/{gss}'))
      end.to raise_error(ArgumentError, /area_codes/)
    end
  end

  describe 'a topic page' do
    let(:homeless) do
      Topics::Topic.find('homes').questions.
        find { _1.text.include?('homeless or in temporary accommodation') }
    end

    it "links each nation's question to its own table, and says what the table is" do
      get topic_question_path('homes', homeless.slug)
      card = page.at_css('.topic-question__main .triage-card')
      expect(card.at_css('a.topic-out')['href']).to eq('https://statistics.example/homelessness')
      expect(card.at_css('.topic-page__note').text).
        to include('by council', 'quarterly')

      get topic_question_path('homes', homeless.slug, nation: 'scotland')
      card = page.at_css('.topic-question__main .triage-card')
      expect(card.at_css('a.topic-out')['href']).to eq(Topics::Dataset.find('glenmoor-homelessness').url)
    end

    it 'still lists a published source on Who holds it when no question links to it' do
      get '/topics/policing/who-holds-it'
      expect(page.css('.topic-published a').map { _1['href'] }).to include('https://crime-maps.example/')
    end
  end

  describe 'an authority page' do
    let(:council) do
      FactoryBot.create(:public_body,
                        name: 'Synthetic Borough Council',
                        tag_string: 'london_borough gss:E09000033')
    end
    let(:area_table) do
      Topics::Dataset.new('id' => 'northmoor-homelessness',
                          'publisher' => 'Synthetic publisher',
                          'title' => 'Synthetic area table',
                          'url' => 'https://example.invalid/table',
                          'kind' => 'table', 'status' => 'open',
                          'nations' => ['england'], 'frequency' => 'quarterly',
                          'area_url' => 'https://example.invalid/area/{gss}',
                          'area_codes' => %w[E09])
    end

    it "opens a table at the council's own area when the table takes its ONS code" do
      allow(Topics::Dataset).to receive(:find).and_call_original
      allow(Topics::Dataset).to receive(:find).
        with('northmoor-homelessness').and_return(area_table)
      get "/body/#{council.url_name}"
      link = page.at_css('#body-figures ~ ul a')
      expect([link.text, link['href']]).
        to eq(['Synthetic area table (another site)',
               'https://example.invalid/area/E09000033'])
    end

    it 'lists no figures where no table takes the code' do
      get "/body/#{council.url_name}"
      expect(page.at_css('#body-figures')).to be_nil
    end

    it 'lists no figures, rather than failing, for a council with no gss: tag' do
      allow(Topics::Dataset).to receive(:find).and_call_original
      allow(Topics::Dataset).to receive(:find).
        with('northmoor-homelessness').and_return(area_table)
      council.update!(tag_string: 'london_borough')
      get "/body/#{council.url_name}"
      expect(response).to have_http_status(:ok)
      expect(page.at_css('#body-figures')).to be_nil
    end
  end
end
