require 'spec_helper'

RSpec.describe 'The menu', feature: :alaveteli_pro do
  include_context 'with incoming attention off'

  let(:owner) do
    FactoryBot.create(:user, name: 'Rowan Requester', trusted: true)
  end
  let(:body) do
    FactoryBot.create(:public_body, name: 'Cowes Example Council',
                                    tag_string: 'local_council county_council')
  end
  let(:context) do
    { topic: 'streets', nation: 'england', holder: 'local_council' }
  end

  def page
    Nokogiri::HTML(response.body)
  end

  before do
    sign_in(owner)
  end

  def write(letter, **options)
    post alaveteli_pro_info_requests_path, params: {
      info_request: { title: 'Table tennis grants', public_body_id: body.id },
      outgoing_message: { letter: letter }, journey: context, **options
    }
  end

  it 'replaces Dashboard and Requests with Home' do
    get alaveteli_pro_dashboard_path
    nav = page.css('#navigation a').map(&:text)
    expect(nav).to include('Home')
    expect(nav).not_to include('Dashboard', 'Requests')
  end

  it 'links the existing dashboard for the authorized owner' do
    get '/help/about'
    link = page.at_css('#dashboard-link')
    expect(link['href']).to eq('/pro/dashboard')
    expect(link.text).to eq('Home')
  end

  it 'makes Make request carry the same search words, authority and nation as the results action' do
    heading = Category.create!(title: 'Place',
                               description: '',
                               parent_ids: [PublicBody.category_root.id])
    Category.create!(title: 'England',
                     description: '',
                     category_tag: 'england',
                     parent_ids: [heading.id])
    body.update!(tag_string: 'local_council county_council england')
    get '/documents', params: { q: 'Table tennis',
                                body: body.url_name,
                                group: 'england',
                                topic: 'streets' }
    expect(page.at_css('#make-request-link')['href']).
      to eq(page.at_css('.search-request a')['href'])
  end

  it 'carries a topic nation through the top navigation without choosing a question for the user' do
    get '/topics/streets', params: { nation: 'scotland' }
    expect(response.headers['Cache-Control']).to include('private', 'no-store')
    expect(page.at_css('#make-request-link').text).to eq('Make request')
    get page.at_css('#make-request-link')['href']
    expect(page.at_css('#content h1').text).to eq('Who holds it?')
    expect(page.at_css('[name="journey[nation]"]')['value']).to eq('scotland')
    expect(page.at_css('[name="journey[topic]"]')['value']).to eq('streets')
    expect(page.at_css('[name="subject"]')).to be_nil
  end

  it 'uses native forms to keep live wording when resuming or visiting topics from the menu' do
    get new_alaveteli_pro_info_request_path(public_body: body.url_name,
                                            subject: 'Table tennis',
                                            step: 'write')
    follow_redirect!
    nav = page.at_css('#make-request-link')
    expect([nav.name, nav['form'], nav['name'], nav['value']]).
      to eq(%w[button write_form journey_step write])
    expect(page.css('.navigation button[form="write_form"]').
             map { |node| node['value'] }).
      to include('topics', 'documents', 'authorities')
    write('Please provide the edited grants register.',
          journey_destination: 'topics')
    follow_redirect!
    get page.at_css('.triage-replies--topics a')['href']
    get page.at_css('#make-request-link')['href']
    expect(page.at_css('#outgoing_message_letter').text).
      to include('edited grants register')
    expect(page.at_css('#info_request_title')['value']).
      to eq('Table tennis grants')
    expect(owner.info_requests).to be_empty
  end

  it 'keeps native navigation after a validation error so corrected words are saved' do
    write('', review: 1)
    follow_redirect!
    expect(page.at_css('#content h1').text).to eq('Write request')
    expect(page.at_css('#make-request-link')['form']).to eq('write_form')
    expect(page.css('.navigation button[form="write_form"]').map(&:text)).
      to include('Topics')
    draft = owner.draft_info_requests.last
    write('Please provide the corrected register.',
          draft_id: draft.id,
          journey_destination: 'topics')
    follow_redirect!
    get page.at_css('#make-request-link')['href']
    expect(page.at_css('#outgoing_message_letter').text).
      to include('corrected register')
  end
end
