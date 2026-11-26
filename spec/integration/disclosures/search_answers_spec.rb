require 'spec_helper'

RSpec.describe 'Search answers' do
  def page
    Nokogiri::HTML(response.body)
  end

  def type_group(tag, title)
    heading = Category.find_by(title: 'Type') ||
              Category.create!(title: 'Type',
                               description: '',
                               parent_ids: [PublicBody.category_root.id])
    Category.create!(
      title: title, description: '', category_tag: tag, parent_ids: [heading.id]
    )
  end

  it 'keeps the masthead search going to the document results, titled with the words' do
    get '/search', params: { query: 'potholes' }
    expect(response).to redirect_to('/documents?q=potholes')
    get '/documents', params: { q: 'potholes' }
    expect(page.at_css('#content h1').text).to eq('Search results')
  end

  it 'says who holds it from the topic files' do
    get '/documents', params: { q: 'potholes' }
    answer = page.at_css('#answer-who').parent
    expect(answer.at_css('.search-answer__who').text).
      to eq('Your county or unitary council')
    expect(answer.at_css('.search-answer__what').text).
      to eq('Local roads, potholes and street lights')
    expect(answer.at_css('.search-answer__from a')['href']).
      to eq('/topics/streets')
  end

  it 'lists up to three authorities whose names match, and nothing for words that name none' do
    body = FactoryBot.create(:public_body, name: 'Zorbington Borough Council')
    get '/documents', params: { q: 'zorbington' }
    expect(page.css('#answer-authorities ~ ul a').map(&:text)).
      to eq([body.name])
    get '/documents', params: { q: 'potholes' }
    expect(page.at_css('#answer-authorities')).to be_nil
  end

  it 'gives the groups and their counts, not every authority, when many match' do
    type_group('district_council', 'District councils')
    type_group('county_council', 'County councils')
    3.times do |n|
      FactoryBot.create(:public_body,
                        name: "Placeholder #{n} Quorbish District Council",
                        tag_string: 'district_council')
    end
    FactoryBot.create(:public_body,
                      name: 'Quorbish County Council',
                      tag_string: 'county_council')
    get '/documents', params: { q: 'quorbish' }
    box = page.at_css('#answer-authorities').parent
    expect(box.css('li').map { _1.text.squish }).
      to eq(['District councils', 'County councils'])
    expect(box.at_css('.search-answer__all a').then { [_1.text, _1['href']] }).
      to eq(['All 4 authorities', '/body/list/all?public_body_query=quorbish'])
  end
end
