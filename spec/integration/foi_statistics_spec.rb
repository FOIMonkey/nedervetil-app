require 'spec_helper'

RSpec.describe 'FOI statistics on authority pages' do
  include ActiveSupport::Testing::TimeHelpers
  include_context 'with production error pages'

  let(:feed) { AuthorityFeeds::Feed.find_by!(key: FoiStatistics::FEED) }
  let(:council) do
    FactoryBot.create(:public_body, name: 'Glenmoor Council',
                                    tag_string: 'local_council sic:glenmoor')
  end
  let(:figures) do
    { 'requests' => 1200, 'on_time' => 600, 'late' => 300, 'no_reply' => 100,
      'full' => 300, 'some' => 200, 'none' => 100, 'not_held' => 400,
      'neither_confirm_nor_deny' => 100, 'refused' => 100 }
  end
  let(:data) do
    { 'source' => FoiStatistics::SOURCE, 'latest' => '2025-26',
      'authorities' => {
        'glenmoor' => {
          'name' => 'Glenmoor Council',
          'note' => 'Figures include the licensing board',
          'years' => { '2024-25' => figures, '2025-26' => figures }
        }
      } }
  end

  def import(data)
    result = AuthorityFeeds::StatisticsJson.new(data.to_json, feed).result
    AuthorityFeeds::Store.new(feed).
      save_figures(result.rows, notes: result.notes)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def record
    page.at_css('.foi-record')
  end

  def figures_shown
    record.css('.foi-record__figures div').map do |row|
      [row.at_css('dt').text, row.at_css('dd').text]
    end
  end

  # The figures are out of date by then, so they stay in the sidebar panel
  # rather than at the top.
  around do |example|
    travel_to(Time.zone.local(2028, 1, 10, 12)) { example.run }
  end

  it 'shows the latest year’s requests, replies on time and releases, leaving out refusals as the Commissioner does' do
    council
    import(data)
    get "/body/#{council.url_name}"
    expect(record.at_css('h2').text).to eq('FOI record, 2025–26')
    expect(record.at_css('.foi-record__requests').text.squish).
      to eq('1,200 requests')
    expect(figures_shown).to eq([['Answered on time', '60%'],
                                 ['Got some or all of the information', '50%']])
    expect(record.at_css('.foi-record__source').text.squish).to eq(
      'Figures include the licensing board. Reported to the Scottish ' \
      'Information Commissioner. Open Government Licence v3.0.'
    )
    expect(record.css('.foi-record__source a').map { |a| a['href'] }).to eq(
      ['https://www.foi.scot/statistics',
       'https://www.nationalarchives.gov.uk/doc/open-government-licence/' \
       'version/3/']
    )
  end

  it 'shows nothing for an untagged or unknown authority, or too few requests' do
    council
    untagged = FactoryBot.create(:public_body, name: 'Elsewhere Council')
    unknown = FactoryBot.create(:public_body, name: 'Typo Council',
                                              tag_string: 'sic:glenmore')
    import(data)
    [untagged, unknown].each do |body|
      get "/body/#{body.url_name}"
      expect(record).to be_nil
    end

    figures['requests'] = FoiStatistics::MIN_REQUESTS - 1
    import(data)
    get "/body/#{council.url_name}"
    expect(record).to be_nil
  end

  it 'shows the year it has when it missed the latest one' do
    council
    data['authorities']['glenmoor']['years'].delete('2025-26')
    import(data)
    get "/body/#{council.url_name}"
    expect(record.at_css('h2').text).to eq('FOI record, 2024–25')
  end

  it 'leaves out a percentage with nothing to divide by' do
    council
    figures.merge!('on_time' => 0, 'late' => 0, 'no_reply' => 0)
    import(data)
    get "/body/#{council.url_name}"
    expect(figures_shown.map(&:first)).
      to eq(['Got some or all of the information'])
  end
end
