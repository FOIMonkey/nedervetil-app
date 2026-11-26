require 'spec_helper'

RSpec.describe 'An authority’s Documents tab' do
  include PublicationFeedHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  def releases_shown
    Nokogiri::HTML(response.body).css('.body-elsewhere .group-page__external').
      map do |link|
        link.text.squish.delete_suffix(' (another site)')
      end
  end

  it 'pages releases apart from documents, so every release can be reached' do
    make_feed_document
    body = @feed_authority
    titles = (1..25).map do |n|
      AuthorityGroups::ExternalRelease.create!(
        public_body: body, title: format('Release %02d', n),
        released_on: Date.new(2026, 1, 1) + n,
        url: "https://log.example.invalid/release-#{n}"
      ).title
    end.reverse
    walk = ->(params) do
      (1..4).flat_map do |n|
        get "/body/#{body.url_name}/documents",
            params: params.merge(releases_page: n)
        expect(response).to have_http_status(:ok)
        releases_shown
      end
    end

    expect(walk.call({})).to eq(titles)
    get "/body/#{body.url_name}/documents"
    expect(releases_shown.size).to eq(10)
    expect(Nokogiri::HTML(response.body).css('.groups-pager a[rel="next"]').
             map { |link| link['href'] }).
      to eq(["/body/#{body.url_name}/documents?releases_page=2"])
    expect(walk.call(q: 'Release')).to eq(titles)
    get "/body/#{body.url_name}/documents",
        params: { host: 'evil.example', releases_page: 2 }
    expect(Nokogiri::HTML(response.body).css('.groups-pager a').
             map { |link| link['href'] }).to all(start_with('/body/'))
  end
end
