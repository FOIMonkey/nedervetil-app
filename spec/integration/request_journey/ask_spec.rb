require 'spec_helper'

RSpec.describe 'Asking, with choices carried', feature: :alaveteli_pro do
  include_context 'with incoming attention off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:council) {
    FactoryBot.create(:public_body,
                      name: 'Northmoor County Council',
                      tag_string: 'local_council county_council')
  }

  def page
    Nokogiri::HTML(response.body)
  end

  def step
    page.at_css('[aria-current="step"]').text.squish
  end

  def check_and_send(letter, title: 'Gritting routes 2025', **extra)
    sending = extra.delete(:send)
    post '/pro/info_requests', params: {
      info_request: { title: title, public_body_id: council.id },
      outgoing_message: { letter: letter },
      review: (1 unless extra[:save_draft]), **extra
    }
    return unless sending

    follow_redirect! if response.redirect?
    form = page.at_css('#send_form')
    return unless form

    post form['action'], params: {
      draft_id: form.at_css('[name="draft_id"]')['value'],
      review_token: form.at_css('[name="review_token"]')['value'],
      send: 1
    }
  end

  describe RequestLetter do
    it 'makes a first subject from the question' do
      expect(described_class.subject('how many potholes were reported in ' \
                                     '2025?')).to eq('How many potholes were ' \
                                                     'reported in 2025')
      long = 'Please tell me how much the council spent on temporary ' \
             'accommodation for homeless families in every year since 2019'
      expect(described_class.subject(long)).
        to eq('Please tell me how much the council spent on temporary ' \
              'accommodation for…')
      expect(described_class.subject("Gritting routes\nand salt stocks")).
        to eq('Gritting routes')
    end
  end

  describe RequestJourney::Checks do
    it 'shows one check, from the letter alone: all emails first, then a letter about the writer' do
      expect(described_class.for(
        'Please send all emails between the leader and the developer.'
      ).line).to eq('Name the records')
      about = described_class.for('Please send a copy of my file and the ' \
                                  'notes about my tenancy.')
      expect([about.line, about.note, about.link.first]).
        to eq(['About you?', 'Ask for your own records with a subject access ' \
                             'request.', 'Ask for own records'])
      expect(described_class.for('All correspondence about my planning ' \
                                 'application.').line).to eq('Name the records')
      # The evidence favours no advice for a list of many questions.
      expect(described_class.for("1. How many?\n2. How much?\n3. Which " \
                                 "suppliers?\n4. Contracts?\n5. When?\n6. " \
                                 "Who?")).to be_nil
    end
  end

  describe Topics::Suggestions do
    it 'matches a question before an authority is chosen, with England’s answers' do
      found = described_class.questions(nil,
                                        'How many abandoned vehicles were ' \
                                        'removed in 2024?')
      expect(found.map(&:title)).
        to eq(['How many abandoned vehicles were removed?'])
      expect(found.first.url).to eq(Topics::Dataset.find('northmoor-abandoned-vehicles').url)
      expect(described_class.documents(nil, 'gritting routes')).to eq([])
    end

    it 'says who a question like this is usually asked of, for every tag the topics ask' do
      expect(described_class.usually('tag' => 'local_council')).
        to eq(['Councils usually hold this.', 'Search for yours.'])
      tags = Topics::Topic.all.flat_map(&:questions).filter_map { |question|
        question.ask&.dig('tag')
      }.uniq
      expect(tags - described_class::HOLDERS.keys).to eq([])
    end
  end

  it 'starts with Who, then asks for a subject' do
    sign_in(owner)
    get new_alaveteli_pro_info_request_path
    expect(page.at_css('#content h1').text).to eq('Who holds it?')
    expect(page.css('.flow-rail__name').map(&:text)).
      to eq(['Who', 'Subject', 'Write request', 'Check and send'])
    get new_alaveteli_pro_info_request_path(public_body: council.url_name,
                                            subject: ' ',
                                            check: 1)
    expect(page.at_css('#subject-error').text.squish).
      to eq('Subject missing Add a short title.')
  end

  it 'checks publications after Who and Subject, then carries the topic question into the letter' do
    sign_in(owner)
    question = 'How many abandoned vehicles were removed from Mill Lane in ' \
               '2024?'
    get new_alaveteli_pro_info_request_path(public_body: council.url_name,
                                            question: question,
                                            check: 1)
    expect(page.at_css('.request-suggestions h2').text).
      to eq('Possible matches')
    expect(page.at_css('input#subject')['value']).
      to eq(RequestLetter.subject(question))
    get new_alaveteli_pro_info_request_path(
      public_body: council.url_name,
      question: question,
      subject: RequestLetter.subject(question),
      step: 'write'
    )
    follow_redirect!
    expect(page.at_css('#content h1').text).to eq('Write request')
    expect(page.at_css('textarea[name="outgoing_message[letter]"]').text.strip).
      to eq(question)
    expect(page.css('.request-check__actions button').map(&:text)).
      to eq(['Save draft', 'Check and send'])
    expect(page.css('#write_form button[name="journey_step"]').map { |button|
                      button['value']
                    }).to eq(%w[who publications])
  end

  it 'goes straight on when nothing is published, and skips Who when the authority is known' do
    sign_in(owner)
    get new_alaveteli_pro_info_request_path(
      question: 'Please provide the gritting routes for 2025.'
    )
    expect(page.at_css('#content h1').text).to eq('Who holds it?')

    get new_alaveteli_pro_info_request_path(public_body: council.url_name)
    expect(page.at_css('.request-to__name strong').text).to eq(council.name)
    expect(page.at_css('input[name="public_body"]')['value']).
      to eq(council.url_name)
    get new_alaveteli_pro_info_request_path(public_body: council.url_name,
                                            question: 'Please provide the ' \
                                                      'gritting routes.',
                                            check: 1)
    follow_redirect!
    expect(page.at_css('#content h1').text).to eq('Write request')
  end

  it 'shows at most one check on Check and send' do
    sign_in(owner)
    check_and_send('Please send all emails about the gritting contract.')
    follow_redirect!
    expect(page.at_css('#content h1').text).to eq('Check and send')
    expect(page.at_css('.request-check__nudge').text.squish).
      to eq('Name the records Limit it to the people, dates and records you ' \
            'need.')
  end

  it 'saves the letter as typed with Save draft, and sends the letter as edited' do
    sign_in(owner)
    expect {
      check_and_send('Please provide the gritting routes.', save_draft: 1)
    }.to change(DraftInfoRequest, :count).by(1)
    draft = owner.draft_info_requests.last
    expect(draft.body).
      to eq("Dear Northmoor County Council,\n\nPlease provide the gritting " \
            "routes.\n\nYours faithfully,\n\nRowan Requester")
    expect(response).
      to redirect_to(new_alaveteli_pro_info_request_path(draft_id: draft.id))
    follow_redirect!
    expect(page.at_css('textarea[name="outgoing_message[letter]"]').text.strip).
      to eq('Please provide the gritting routes.')
    expect(page.at_css('input[name="draft_id"]')['value']).to eq(draft.id.to_s)

    get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
    expect(response).to have_http_status(:ok)
    expect(page.at_css('#content h1').text).to eq('Check and send')

    check_and_send('Please provide the gritting routes and salt stocks.',
                   title: 'Gritting and salt 2025',
                   draft_id: draft.id,
                   send: 1)
    request = owner.info_requests.last
    expect(request.title).to eq('Gritting and salt 2025')
    expect(request.outgoing_messages.first.body).
      to include('Please provide the gritting routes and salt stocks.')
    expect(owner.draft_info_requests.reload).to be_empty
    follow_redirect!
    expect(page.at_css('.request-band__stamp').text).
      to eq("Sent to #{council.name}")
  end

  it 'keeps the letter on Check and send when core turns it down' do
    sign_in(owner)
    check_and_send('Please provide the routes.', title: '', send: 1)
    expect(owner.info_requests).to be_empty
    expect(page.at_css('#content h1').text).to eq('Write request')
    expect(page.at_css('#errorExplanation, .errorExplanation').text).
      to include('Please enter a summary of your request')
    expect(page.at_css('textarea[name="outgoing_message[letter]"]').text.strip).
      to eq('Please provide the routes.')
  end

  it 'asks again from a copy of the letter, or someone else with the same letter, never from another account’s request' do
    earlier = FactoryBot.create(:info_request, user: owner,
                                               public_body: council,
                                               title: 'Gritting routes 2024')
    earlier.outgoing_messages.first.
      update_columns(body: RequestLetter.join('Please provide the 2024 routes.',
                                              council.name,
                                              owner.name))
    other = FactoryBot.create(:public_body, name: 'Southmere District Council')
    sign_in(owner)

    get new_alaveteli_pro_info_request_path(from: earlier.id,
                                            public_body: council.url_name)
    follow_redirect!
    expect(page.at_css('#content h1').text).to eq('Write request')
    expect(page.at_css('.request-flow__quiet').text).
      to start_with('Copied from your request of ')
    expect(page.at_css('input[name="info_request[title]"]')['value']).
      to eq('Gritting routes 2024')
    expect(page.at_css('textarea[name="outgoing_message[letter]"]').text.strip).
      to eq('Please provide the 2024 routes.')

    get new_alaveteli_pro_info_request_path(from: earlier.id,
                                            query: 'Southmere')
    expect(page.at_css('.request-flow__quiet').text).
      to include('Gritting routes 2024')
    get page.at_css('.authority-results__name')['href']
    follow_redirect! if response.redirect?
    expect(page.css('.request-sheet__fixed').first.text).
      to eq('Dear Southmere District Council,')
    expect(page.at_css('textarea[name="outgoing_message[letter]"]').text.strip).
      to eq('Please provide the 2024 routes.')
    expect(page.at_css('input[name="info_request[public_body_id]"]')['value']).
      to eq(other.id.to_s)

    someone = FactoryBot.create(:info_request, public_body: council,
                                               title: 'Not yours')
    get new_alaveteli_pro_info_request_path(from: someone.id,
                                            public_body: council.url_name)
    expect(page.at_css('#content h1').text).to eq('Request subject')
    expect(response.body).not_to include('Not yours')
  end

  it 'keeps the letter when the authority changes with a draft open' do
    sign_in(owner)
    check_and_send('Please provide the routes.', save_draft: 1)
    draft = owner.draft_info_requests.last
    other = FactoryBot.create(:public_body, name: 'Southmere District Council')
    get new_alaveteli_pro_info_request_path(draft_id: draft.id, change: 1)
    expect(page.at_css('#content h1').text).to eq('Who holds it?')
    get new_alaveteli_pro_info_request_path(draft_id: draft.id,
                                            public_body: other.url_name)
    expect(page.at_css('.request-sheet__to b').text).to eq(other.name)
    expect(page.css('.request-sheet__fixed').first.text).
      to eq('Dear Southmere District Council,')
    expect(page.at_css('textarea[name="outgoing_message[letter]"]').text.strip).
      to eq('Please provide the routes.')
  end
end
