require 'spec_helper'

RSpec.describe 'Published answers under the question' do
  include ActiveJob::TestHelper
  include_context 'with incoming attention off'
  include_context 'with document OCR off'

  let(:council) {
    FactoryBot.create(:public_body,
                      name: 'Northmoor County Council',
                      tag_string: 'local_council county_council')
  }
  let(:scottish) {
    FactoryBot.create(:public_body, name: 'Glenmoor Council',
                                    tag_string: 'local_council ' \
                                                'scottish_council scotland')
  }
  let(:trust) {
    FactoryBot.create(:public_body,
                      name: 'Northmoor Hospitals NHS Trust',
                      tag_string: 'nhs_trust')
  }
  let(:police) {
    FactoryBot.create(:public_body, name: 'Northmoor Police',
                                    tag_string: 'police')
  }
  let(:admin) { FactoryBot.create(:admin_user) }

  def titles(body, text)
    Topics::Suggestions.questions(body, text).map(&:title)
  end

  def published(title, description: nil, body: council)
    request = FactoryBot.create(:info_request, public_body: body,
                                               title: 'Some figures')
    message = AttachmentFixtures.deliver(request, [['records.txt',
                                                    'text/plain',
                                                    "Figures\n"]])
    attachment = message.get_attachments_for_display.find { |a|
      a.filename == 'records.txt'
    }
    document = Disclosures::Creation.new(user: request.user,
                                         attachment: attachment,
                                         kind: 'released_records').create!
    document.reload.update!(title: title, description: description)
    Disclosures::Publication.new(document, user: admin).publish!
    document.reload
  end

  it 'suggests the published table for the authority’s nation, from keywords in any order or form' do
    england = Topics::Suggestions.questions(council,
                                            'How many incidents of abandoned ' \
                                            'cars were there on Mill Lane?')
    expect(england.map(&:title)).
      to eq(['How many abandoned vehicles were removed?'])
    expect(england.first.url).to eq(Topics::Dataset.find('northmoor-abandoned-vehicles').url)
    expect(england.first.note).to start_with(Topics::Dataset.find('northmoor-abandoned-vehicles').title)

    scotland = Topics::Suggestions.questions(
      scottish,
      'How many penalty charge notices were issued in 2024, by street?'
    )
    expect(scotland.map(&:title)).
      to eq(['How many parking fines were issued, and where?'])
    expect(scotland.first.url).to eq(Topics::Dataset.find('glenmoor-parking-fines').url)
    expect(scotland.first.partial).to be(true)
  end

  it 'leaves out questions with nothing published in that nation, or asked of another kind of authority' do
    expect(titles(council, 'How many potholes were repaired?')).to eq([])
    expect(titles(council, 'How much was spent on agency staff?')).to eq([])
    expect(titles(trust, 'How much was spent on agency staff?')).
      to eq(['How much does the trust spend on agency staff?'])
    expect(titles(council, 'Please give spending by service for 2024.')).
      to eq(['What does the council spend on each service?'])
    expect(titles(trust, 'Please give spending by service for 2024.')).to eq([])
    expect(titles(trust, 'How long did patients wait in A&E last winter?')).
      to eq(['How long do patients wait in A&E?'])
    expect(titles(council, 'Please provide the gritting routes.')).to eq([])
    expect(titles(council, 'How much was spent on children’s social care?')).
      to eq([])
    expect(titles(council,
                  'How many children in care were placed out of ' \
                  'area?')).to eq(['How many children are in council care?'])
    expect(titles(council, '')).to eq([])
  end

  it 'ranks fuller keyword matches first and shows three at most' do
    text = 'How many abandoned vehicles, homeless households in temporary ' \
           'accommodation, empty homes and ' \
           'children in care were there?'
    found = titles(council, text)
    expect(found.size).to eq(3)
    expect(found.first).
      to eq('How many people are homeless or in temporary accommodation?')
  end

  it 'suggests a "how many" table only where the letter asks for a quantity near the keyword' do
    expect(titles(trust,
                  'Please send the minutes of meetings about agency ' \
                  'staff.')).to eq([])
    expect(titles(trust,
                  "Who chairs the agency staff panel?\nPlease send its terms " \
                  "of reference.\n" \
                         'What were its total costs for 2024?')).to eq([])
    expect(titles(trust,
                  'Please describe your use of agency staff. Give the total ' \
                  'spent each year.')).
      to eq(['How much does the trust spend on agency staff?'])
    expect(titles(trust,
                  "1. Agency staff by ward 2. The cost of each shift\n3. Who " \
                  "approves it")).
      to eq(['How much does the trust spend on agency staff?'])
    # Not a quantity question, so not held back.
    expect(titles(council, 'Please give spending by service.')).
      to eq(['What does the council spend on each service?'])
  end

  it 'leaves out keywords that letters use in passing' do
    expect(titles(council,
                  'We are an Ofsted-registered children’s home. How many ' \
                  'placements do you make?')).to eq([])
    expect(titles(council, 'How many staff are in the Homelessness team?')).
      to eq([])
    expect(titles(council,
                  'How many homeless households were placed in hotels?')).
      to eq(['How many people are homeless or in temporary accommodation?'])
  end

  it 'finds what authorities pointed similar letters to under section 21' do
    response = Topics::Suggestions.questions(police,
                                             'What was your average response ' \
                                             'time to Grade 1 incidents?')
    expect(response.map(&:title)).
      to eq(['How fast does the force reach emergencies?'])
    expect(response.first).
      to have_attributes(url: Topics::Dataset.find('northmoor-police-response').url,
                         partial: true)
    expect(titles(council,
                  'What was your average response time to Grade 1 ' \
                  'incidents?')).to eq([])
    expect(
      titles(
        council,
        'A. The number of residential homes standing empty for more than two ' \
        'years.'
      )
    ).to eq(['How many homes are empty?'])
    expect(titles(trust,
                  'Please provide details in respect to the contract below. ' \
                  'What are the contractual ' \
                         'performance KPIs for this ' \
                         'contract?')).to eq(['Who holds the contract, and ' \
                                              'when does it end?'])
    expect(titles(trust,
                  'Waste type, incumbent contractor, contract start and ' \
                  'length of the contract.')).
      to eq(['Who holds the contract, and when does it end?'])
    # Public spending reaches councils only through its holder's link, not
    # through an authority-type group.
    expect(titles(council,
                  'What are the contractual performance KPIs for this ' \
                  'contract?')).
      to eq(['Who holds the contract, and when does it end?'])
  end

  it 'suggests published documents sharing the letter’s less common words, this authority’s first' do
    other = FactoryBot.create(:public_body, name: 'Southmoor District Council')
    elsewhere = published('Fly-tipping clearance costs 2023', body: other)
    own = published('Fly-tipping clearance costs 2024')
    described = published('Street cleaning and clearance',
                          description: 'Fly-tipping removal by ward')
    published('Gritting routes and salt stores')
    published('Council spending 2024 figures')

    found = Topics::Suggestions.documents(council,
                                          'Please provide the cost of ' \
                                          'fly-tipping clearance in each year.')
    expect(found.map(&:id)).to eq([own.id, elsewhere.id, described.id])
    expect(found.first).to be_a(Disclosures::PublicDocument)
    expect(Topics::Suggestions.documents(
             council,
      'Please provide the council spending figures for 2024.'
           )).to eq([])
  end

  it 'never suggests a withdrawn document' do
    document = published('Fly-tipping clearance costs 2024')
    Disclosures::Publication.new(document, user: admin).withdraw!(
      reason: 'Synthetic check'
    )
    expect(Topics::Suggestions.documents(council,
                                         'Fly-tipping clearance costs')).
      to eq([])
  end

  describe 'Check and send', feature: :alaveteli_pro do
    let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }

    before do
      sign_in(owner)
    end

    def check(title, letter)
      post '/pro/info_requests', params: {
        info_request: { title: title, public_body_id: council.id },
        outgoing_message: { body: RequestLetter.join(letter,
                                                     council.name,
                                                     owner.name) },
        review: 1
      }
      follow_redirect! while response.redirect?
      Nokogiri::HTML(response.body)
    end

    def ask(question)
      get new_alaveteli_pro_info_request_path(public_body: council.url_name,
                                              question: question,
                                              check: 1)
      follow_redirect! if response.redirect?
      Nokogiri::HTML(response.body)
    end

    it 'shows published answers under the question, opening in a new tab, and nothing when none match' do
      document = published('Abandoned vehicle removal costs 2024')
      page = ask('Abandoned vehicle removal costs')
      links = page.css('.request-suggestions a')
      expect(links.map(&:text)).
        to eq(['How many abandoned vehicles were removed?',
               'Abandoned vehicle removal costs 2024'])
      expect(links.map { |link| link['target'] }.uniq).to eq(['_blank'])
      expect(links.last['href']).
        to start_with(disclosure_document_path(document))
      expect(page.at_css('.request-question__field + .request-suggestions')).
        to be_present

      gritting = ask('Please provide the gritting routes for 2025.')
      expect(gritting.at_css('.request-suggestions')).to be_nil
      expect(gritting.at_css('#content h1').text).to eq('Write request')
    end

    it 'points to the authority’s own disclosure log, or else its publication scheme' do
      council.update!(publication_scheme: 'https://northmoor.example/publication-scheme')
      line = check('Gritting',
                   'Please provide the gritting ' \
                   'routes.').at_css('.request-flow__published')
      expect(line.text.squish).
        to eq('Its publication scheme (another site, opens in a new tab) may ' \
              'already have it.')
      expect(line.at_css('a')['href']).to eq('https://northmoor.example/publication-scheme')

      council.update!(disclosure_log: 'https://northmoor.example/disclosure-log')
      link = check('Gritting',
                   'Please provide the gritting ' \
                   'routes.').at_css('.request-flow__published a')
      expect([link.text, link['href'], link['target']]).
        to eq(['Its disclosure log (another site, opens in a new ' \
               'tab)', 'https://northmoor.example/disclosure-log', '_blank'])

      council.update!(disclosure_log: '', publication_scheme: '')
      expect(check('Gritting',
                   'Please provide the gritting ' \
                   'routes.').at_css('.request-flow__published')).to be_nil
    end
  end
end
