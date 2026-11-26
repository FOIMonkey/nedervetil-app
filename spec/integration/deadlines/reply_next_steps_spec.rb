require 'spec_helper'

RSpec.describe 'A reply and its next steps', feature: :alaveteli_pro do
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
  let(:user) { FactoryBot.create(:pro_user, name: 'Rowan Requester') }
  let(:council) {
    FactoryBot.create(:public_body,
                      name: 'Northmoor County Council',
                      tag_string: 'local_council county_council')
  }
  let(:fife) {
    FactoryBot.create(:public_body, name: 'Fife Council',
                                    tag_string: 'local_council ' \
                                                'scottish_council scotland')
  }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:replied) { Time.zone.parse('2026-09-28 11:00') }
  let(:today) { Time.zone.parse('2026-09-29 12:00') }
  let(:letter) {
    "Dear Rowan Requester,\n\nPlease find attached our response, " \
    "and the gritting routes for 2025.\n\nInformation Rights\n"
  }

  def sent(body = council, title: 'Gritting routes')
    travel_to(start) {
      FactoryBot.create(:info_request, user: user,
                                       public_body: body,
                                       title: title)
    }
  end

  def reply_to(request, at: replied, text: letter)
    travel_to(at) {
      AttachmentFixtures.deliver(request, [['Routes 2025.csv',
                                            'text/csv',
                                            "route,road\n1,A1\n"]], text: text)
    }
  end

  # Core's session lasts hours from the last request, so sign in at the
  # test's own time.
  def visit(path, at: today)
    travel_to(at) do
      sign_in(user)
      get path
    end
    Nokogiri::HTML(response.body)
  end

  def send_post(path, params, at: today)
    travel_to(at) { post path, params: params }
  end

  it 'shows who replied and when, offers what to do, and keeps the letter in the feed' do
    request = sent
    message = reply_to(request)
    page = visit("/request/#{request.url_title}")
    receipt = page.at_css('.receipt')
    expect(receipt.at_css('h2').text.squish).
      to eq("#{request.public_body.short_name} replied on time · 28 Sep")
    # The question is the one yellow thing on the page until it's answered.
    expect(receipt.at_css('.receipt__act--primary')).to be_nil
    links = receipt.css('.receipt__acts a').to_h { |link|
      [link.text, link['href']]
    }
    expect(links.keys).to eq(['Share documents', 'Reply', 'Ask for review'])
    expect(links['Share documents']).
      to eq(publish_reply_path(url_title: request.url_title,
                               message_id: message.id))
    expect(links['Reply']).
      to eq("/request/#{request.url_title}/followups/new/#{message.id}")
    more = receipt.css('.receipt__next li').to_h { |row|
      [row.at_css('a').text, row.at_css('a')['href']]
    }
    expect(more['Ask again']).
      to eq(new_alaveteli_pro_info_request_path(from: request.id,
                                                public_body: council.url_name))
    expect(more['Ask someone else']).
      to eq(new_alaveteli_pro_info_request_path(from: request.id))
    expect(receipt.at_css('.receipt__said').text).
      to include('the gritting routes for 2025')
    expect(receipt.at_css('fieldset legend').text).
      to eq('Did you get what you asked for?')
    expect(receipt.css('.receipt__chip').map(&:text)).
      to eq(['All of it', 'Some of it', 'None of it'])
    expect(receipt.css('.attachment__name').map { |name| name.text.strip }).
      to include('Routes 2025.csv')
    expect(receipt.at_css('.receipt__letter a')['href']).
      to eq("#reply-#{message.id}")
    row = page.at_css("#reply-#{message.id}")
    expect(row.key?('open')).to be(false)
    expect(row.at_css('.receipt__ask')).to be_nil
    expect(row.css('.attachment')).to be_empty
    expect(row.text).to include('the gritting routes for')
    expect(response.body).not_to include('Read it, then set the status')
  end

  it 'offers the same next steps and question without the Pro role',
     feature: { alaveteli_pro: false } do
    request = sent
    reply_to(request)
    receipt = visit("/request/#{request.url_title}").at_css('.receipt')
    expect(receipt.css('.receipt__next li a').map(&:text)).
      to eq(['Ask again', 'Ask someone else'])
    expect(receipt.at_css('.receipt__ask')['action']).
      to eq(alaveteli_pro_classifications_path(url_title: request.url_title))
  end

  def page_has_no_question?(request)
    visit("/request/#{request.url_title}").at_css('.receipt__ask').nil?
  end

  it 'asks a suspended requester nothing' do
    request = sent
    reply_to(request)
    user.update!(ban_text: 'Spam')
    page = visit("/request/#{request.url_title}")
    expect(page.at_css('.receipt')).to be_present
    expect(page.at_css('.receipt__ask')).to be_nil
    actions = page.css('form').map { |form| form['action'] }
    expect(actions).not_to include(
      alaveteli_pro_classifications_path(url_title: request.url_title),
      classifications_path(url_title: request.url_title)
    )
  end

  it 'records the answer to the question, and says what follows from it' do
    request = sent
    reply_to(request)
    form = visit("/request/#{request.url_title}").at_css('.receipt__ask')
    expect(form).to be_present
    send_post(form['action'],
              { 'classification[described_state]' => 'partially_successful',
                :last_info_request_event_id =>
                  form.at_css('[name=last_info_request_event_id]')['value'] })
    expect(request.reload.described_state).to eq('partially_successful')
    travel_to(today) { follow_redirect! }
    expect(Nokogiri::HTML(response.body).at_css('.band-flash')).to be_nil
    receipt = visit("/request/#{request.url_title}").at_css('.receipt')
    expect(receipt.at_css('.receipt__got').text).
      to eq('You got some of it.')
    expect(receipt.at_css('.receipt__change')['href']).
      to eq('#describe_state_form_1')
    expect(receipt.at_css('.receipt__act--primary').text).
      to eq('Share documents')
    coming = visit("/request/#{request.url_title}").
             at_css('.request-feed--next .feed__row')
    expect(coming.text.squish).to eq('23 Nov Last day to ask for a review')
    expect(coming.at_css('a')['href']).to include('internal_review=1')
    expect(page_has_no_question?(request)).to be(true)
    expect(receipt.css('.receipt__acts a').map(&:text)).
      to include('Ask for review')

    travel_to(today) { request.set_described_state('successful') }
    receipt = visit("/request/#{request.url_title}").at_css('.receipt')
    expect(receipt.at_css('.receipt__got').text).to eq('You got all of it.')
    expect(receipt.css('.receipt__acts a, .receipt__next a').map(&:text)).
      to eq(['Share documents', 'Reply', 'Ask again', 'Ask someone else'])
  end

  it 'points to admin review from the latest reply when requesters can’t publish' do
    allow(AlaveteliConfiguration).
      to receive(:disclosures_requester_editing).and_return(false)
    with_setting(Disclosures, :requester_editing, nil) do
      request = sent
      message = reply_to(request)
      Disclosures::Suggester.new(message).run
      page = visit("/request/#{request.url_title}")
      expect(page.at_css('.receipt .documents-todo').text).
        to include('Routes 2025.csv')
      expect(page.at_css("#reply-#{message.id} .documents-todo")).to be_nil
    end
  end

  it 'says when a reply came late' do
    request = sent
    reply_to(request, at: Time.zone.parse('2026-10-09 11:00'))
    page = visit("/request/#{request.url_title}",
                 at: Time.zone.parse('2026-10-09 12:00'))
    expect(page.at_css('.receipt h2').text.squish).
      to eq("#{request.public_body.short_name} replied late · 9 Oct")
  end

  it 'shows the reply for context and sends only the composed follow-up' do
    request = sent
    message = reply_to(request)
    page = visit("/request/#{request.url_title}/followups/new/#{message.id}")
    expect(page.at_css('#content h1').text).to eq('Gritting routes')
    expect(page.at_css('#followup-title').text).
      to eq('Reply to Northmoor County Council')
    expect(page.at_css('.receipt__said footer').text).
      to eq('Their letter, 28 Sep')
    expect(page.css('.request-sheet__fixed').map(&:text).join(' ')).
      to include('Dear Information Rights,',
                 'Yours sincerely,',
                 'Rowan Requester')
    expect(page.at_css('.followup-note').text).
      to eq('If they asked you something, their 20 working days start again ' \
            'when you reply.')
    form = page.at_css('form.followup-form')

    send_post(form['action'], { submitted_followup: 1,
                                outgoing_message: { what_doing: 'normal_sort',
                                                    letter: '' } })
    expect(request.reload.outgoing_messages.where(message_type: 'followup')).
      to be_empty
    expect(Nokogiri::HTML(response.body).at_css('#errorExplanation')).
      to be_present

    ActionMailer::Base.deliveries.clear
    send_post(form['action'], { submitted_followup: 1,
                                outgoing_message: { what_doing: 'normal_sort',
                                                    letter: 'Both, please.' } })
    followup = request.reload.outgoing_messages.find_by(
      message_type: 'followup'
    )
    expect(followup.body).
      to eq("Dear Information Rights,\n\nBoth, please.\n\nYours " \
            "sincerely,\n\nRowan Requester")
    expect(ActionMailer::Base.deliveries.last.to).
      to eq(['foi@synthetic-authority.test'])
    expect(ActionMailer::Base.deliveries.last.body.decoded.strip).
      to eq(followup.body.strip)
    expect(flash[:notice]).
      to eq('Reply sent. If they asked you something, their 20 working days ' \
            'start again today.')
  end

  it 'replies to whoever wrote unless their address takes no replies, and lets the requester choose the main address' do
    request = sent
    message = reply_to(request)
    page = visit("/request/#{request.url_title}/followups/new/#{message.id}")
    expect(page.at_css('.followup-to').text.squish).
      to eq('To the officer who wrote. Or send it to their main FOI address.')
    expect(page.at_css('.followup-to a')['href']).
      to eq("/request/#{request.url_title}/followups/new")

    previous = ReplyToAddressValidator.invalid_reply_addresses
    ReplyToAddressValidator.
      invalid_reply_addresses = previous + ['FOI@synthetic-authority.test']
    expect(IncomingMessage.find(message.id).valid_to_reply_to?).to be(false)
    page = visit("/request/#{request.url_title}/followups/new/#{message.id}")
    expect(page.at_css('.followup-to').text).to eq('To their main FOI address.')
    expect(page.css('.request-sheet__fixed').first.text).
      to eq('Dear Northmoor County Council,')
    ActionMailer::Base.deliveries.clear
    send_post(page.at_css('form.followup-form')['action'],
              { submitted_followup: 1,
                outgoing_message: { what_doing: 'normal_sort',
                                    letter: 'Both, please.' } })
    expect(ActionMailer::Base.deliveries.last.to).to eq([council.request_email])
  ensure
    ReplyToAddressValidator.invalid_reply_addresses = previous
  end

  it 'asks for an internal review with the standard letter, nothing to write' do
    request = sent
    reply_to(request)
    page = visit(
      "/request/#{request.url_title}/followups/new?internal_review=1"
    )
    expect(page.at_css('#content h1').text).to eq('Internal review')
    standard = page.at_css(
      'textarea[name="outgoing_message[letter]"]'
    ).text.strip
    expect(standard).to eq(
      "Please pass this to the person who conducts internal reviews.\n\n" \
      "I am writing to request an internal review of Northmoor County " \
      "Council's handling of my request \"Gritting routes\", " \
      "sent on 7 September 2026.\n\nI am not satisfied with your response of " \
      "28 September 2026, and ask you to look at it again."
    )
    facts = page.css('.flow-facts li').map { |fact|
      fact.css('> span').map { |part| part.text.squish }.join(' ')
    }
    expect(facts).
      to eq(['The standard letter It’s all a review needs. Nothing to write.',
             'Ask by 23 Nov After that, they can refuse to review it.',
             'Worth asking About 2 in 5 reviews release something.'])

    send_post(page.at_css('form.followup-form')['action'],
              { submitted_followup: 1,
                internal_review: 1,
                outgoing_message: { letter: standard } })
    review = request.reload.outgoing_messages.find_by(
      what_doing: 'internal_review'
    )
    expect(review.body).
      to start_with("Dear Northmoor County Council,\n\nPlease pass this to " \
                    "the person")
    expect(review.body).to end_with("Yours faithfully,\n\nRowan Requester")
    expect(review.body).not_to include('GIVE DETAILS', 'http')
    expect(flash[:notice]).
      to eq('Review asked. They should reply by 27 October.')
  end

  it 'asks a Scottish review to say what is wrong, picked from five, and builds the letter from it' do
    request = sent(fife, title: 'School transport')
    reply_to(request)
    page = visit(
      "/request/#{request.url_title}/followups/new?internal_review=1"
    )
    expect(page.at_css('#content h1').text).to eq('Review')
    expect(page.at_css('legend').text).to eq('What’s wrong with their answer?')
    expect(page.css('.followup-choice').map { |choice| choice.text.squish }).
      to eq(['They didn’t answer in time',
             'They held some back',
             'They said no to all of it',
             'They say they don’t have it',
             'Something else'])
    expect(page.at_css('[data-review-letter-target="sentence"]').text).
      to eq('Your reason, from your choice above.')
    action = page.at_css('form.followup-form')['action']

    send_post(action, { submitted_followup: 1, internal_review: 1 })
    expect(Nokogiri::HTML(response.body).at_css('#errorExplanation').text).
      to include('Choose what’s wrong with their answer.')
    send_post(action, { submitted_followup: 1,
                        internal_review: 1,
                        review_reason: 'other',
                        review_more: ' ' })
    expect(Nokogiri::HTML(response.body).at_css('#errorExplanation').text).
      to include('Say what’s wrong with their answer.')
    expect(
      request.reload.outgoing_messages.where(what_doing: 'internal_review')
    ).to be_empty

    send_post(action, { submitted_followup: 1,
                        internal_review: 1,
                        review_reason: 'part',
                        review_more: 'They sent 2024 but not 2025.' })
    review = request.reload.outgoing_messages.find_by(
      what_doing: 'internal_review'
    )
    expect(review.body).to eq(
      "Dear Fife Council,\n\nI am writing to require a review of Fife " \
      "Council's handling of my request \"School transport\", " \
      "sent on 7 September 2026.\n\nYou held back part of the information I " \
      "asked for. Please release it, or explain why " \
      "each part is withheld.\n\nThey sent 2024 but not 2025.\n\nYours " \
      "faithfully,\n\nRowan Requester"
    )
    expect(flash[:notice]).to start_with('Review asked. They should reply by ')
  end

  describe 'the time to ask for a review' do
    def refused(request)
      reply_to(request)
      travel_to(replied + 1.hour) {
        request.reload.set_described_state('rejected')
      }
      request
    end

    def routine_reply(request, at:)
      travel_to(at) do
        message = FactoryBot.create(:incoming_message, info_request: request)
        request.log_event('response', incoming_message_id: message.id)
        request.update!(awaiting_description: true)
        IncomingAttention::Classification.automatically do
          request.reload.set_described_state(request.described_state)
        end
        IncomingAttention::Prediction.create!(incoming_message: message,
                                              info_request: request,
                                              status: 'complete',
                                              route: 'SKIP',
                                              needs_check: false,
                                              eligible: true,
                                              restrictions: [],
                                              attempts: 1,
                                              auto_classified: true)
      end
    end

    def offers(request, at:)
      receipt = visit("/request/#{request.url_title}",
                      at: at).at_css('.receipt')
      asks = receipt.css('.receipt__acts a').map(&:text).
             include?('Ask for review')
      form = visit("/request/#{request.url_title}/followups/new" \
                   '?internal_review=1', at: at)
      facts = form.css('.flow-facts li').map { |fact|
        fact.css('> span').map { |part| part.text.squish }.join(' ')
      }
      [asks,
       receipt.at_css('.receipt__got')&.text,
       facts.grep(/\AAsk by/)]
    end

    it 'counts from the decision, not from a routine reply after it' do
      skip 'IncomingAttention arrives in B10' unless defined?(IncomingAttention::Config)
      request = refused(sent)
      routine_reply(request, at: Time.zone.parse('2026-10-20 10:00'))

      expect(offers(request, at: Time.zone.parse('2026-10-21 12:00'))).
        to eq([true, nil,
               ['Ask by 23 Nov After that, they can refuse to review it.']])
      expect(offers(request, at: Time.zone.parse('2026-11-24 12:00'))).
        to eq([false, nil, []])
    end

    it 'keeps to a date the requester changed' do
      request = refused(sent)
      travel_to(Time.zone.parse('2026-09-29 12:00')) do
        Deadlines::Adjustment.apply!(request.reload, stage: 'review_request',
                                                     user: user,
                                                     due_on: Date.new(2026,
                                                                      10,
                                                                      30),
                                                     reason: 'authority_letter')
      end

      expect(offers(request, at: Time.zone.parse('2026-10-29 12:00'))).
        to eq([true, 'You got none of it.',
               ['Ask by 30 Oct After that, they can refuse to review it.']])
      expect(offers(request, at: Time.zone.parse('2026-11-02 12:00'))).
        to eq([false, 'You got none of it.', []])
    end
  end
end
