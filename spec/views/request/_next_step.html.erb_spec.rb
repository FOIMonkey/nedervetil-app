require 'spec_helper'

RSpec.describe 'request/_next_step' do
  include_context 'with incoming attention off'

  let(:user) { FactoryBot.create(:user, trusted: true) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:late) { Time.zone.parse('2026-10-09 12:00') }

  # The partials it renders say what they were handed, and nothing else.
  before do
    allow(controller).to receive(:current_ability).and_return(Ability.new(user))
    stub_template(
      'request/_receipt.html.erb' =>
        '<section class="receipt" data-review-by="<%= review_by %>" ' \
        'data-review-coming-up="<%= review_coming_up ? true : false %>" ' \
        'data-arrived="<%= arrived ? true : false %>" ' \
        'data-change="<%= change ? true : false %>"><%= after %></section>',
      'request/_describe_state.html.erb' =>
        '<form class="describe-state"></form>',
      'request/_attention_choice.html.erb' => '',
      'deadlines/_complete_form.html.erb' =>
        '<form class="complete-form"></form>'
    )
  end

  def request_sent(tags: '')
    travel_to(start) do
      FactoryBot.create(
        :info_request,
        user: user,
        public_body: FactoryBot.create(:public_body, tag_string: tags)
      )
    end
  end

  def reply(request, state = nil, at: start + 7.days)
    travel_to(at) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state(state) if state
      message
    end
  end

  def follow_up(request, factory = :new_information_followup)
    travel_to(start + 8.days) do
      FactoryBot.create(factory, info_request: request.reload)
    end
  end

  def set_state(request, state)
    travel_to(start + 1.day) { request.reload.set_described_state(state) }
  end

  def action_for(request, on:)
    Deadlines::NextAction.for(InfoRequest.find(request.id), today: on.to_date)
  end

  def long(date)
    I18n.l(date, format: '%-d %B')
  end

  # The partial with the locals the requester's page has always given it.
  def next_step(request, on:, owner: true, update_status: false, **locals)
    travel_to(on) do
      request = InfoRequest.find(request.id)
      assign :info_request, request
      assign :user, user
      assign :is_owning_user, owner
      assign :update_status, update_status
      assign :state_transitions,
             request.state.transitions(
               is_owning_user: owner,
               user_asked_to_update_status: update_status
             )
      render partial: 'request/next_step',
             locals: { action: Deadlines::NextAction.for(request),
                       unread: [], fresh: false, arrived: nil, **locals }
    end
    Nokogiri::HTML.fragment(rendered)
  end

  def actions(page)
    page.css('.next-step__actions a, .next-step__actions button, ' \
             '.next-step__actions span').map { |item| item.text.squish }
  end

  describe 'while the authority has time left' do
    it 'says who it waits for and when the reply is due' do
      request = request_sent
      page = next_step(request, on: start + 2.days)
      step = page.at_css('section.next-step--quiet')
      expect(step.at_css('h2').text).
        to eq("Waiting for #{request.public_body.name}")
      expect(step.at_css('p').text).to eq(
        "Reply due #{request.date_response_required_by.strftime('%-d %b')}."
      )
      expect(step.css('a').map { |link| [link.text, link['href']] }).to eq(
        [['Send a followup',
          "/request/#{request.url_title}/followups/new#followup"]]
      )
      expect(page.at_css('.receipt__letter')).to be_nil
      expect(page.at_css('.next-step__after')).to be_nil
      expect(page.at_css('details.next-step__status')).to be_nil
    end

    it 'tells someone who has just sent it what happens next' do
      request = request_sent
      page = next_step(request, on: start + 1.hour, fresh: true)
      expect(page.css('.next-step__after h3').map(&:text)).to eq(
        ['When they reply',
         "If they miss #{long(request.date_response_required_by)}"]
      )
      expect(page.css('.next-step__after p').last.text).
        to eq('You can remind them in one click.')
    end

    it 'links to a reply that is waiting to be read' do
      request = request_sent
      message = reply(request, 'waiting_response')
      page = next_step(request, on: start + 10.days, unread: [message])
      expect(page.at_css('section.next-step--quiet')).to be_present
      link = page.at_css('.receipt__letter a')
      expect([link.text, link['href']]).
        to eq(['Read the new reply', "#reply-#{message.id}"])
    end

    it 'opens the status form when asked to, for someone who may set it' do
      request = request_sent
      page = next_step(request, on: start + 2.days, update_status: true)
      form = page.at_css('details.next-step__status')
      expect(form.key?('open')).to be(true)
      expect(form.at_css('form.describe-state')).to be_present
    end
  end

  describe 'when a reply is late' do
    it 'offers a reminder first under FOI' do
      request = request_sent
      page = next_step(request, on: late)
      step = page.at_css('section.next-step--act')
      expect(step.at_css('h2').text).to eq('Response overdue')
      expect(step.at_css('p').text).
        to eq("It was due on #{long(request.date_response_required_by)}.")
      expect(step.at_css('button.button').text).to eq('Remind them')
      expect(actions(page)).
        to eq(['Remind them', 'Complain to the ICO', 'Send a followup'])
    end

    it 'says when they were reminded, instead of offering it again' do
      request = request_sent
      travel_to(late - 2.days) do
        Deadlines::Reminder.create!(
          info_request: request, user: user, stage: 'response',
          due_on: request.date_response_required_by
        )
      end
      page = next_step(request, on: late)
      expect(page.at_css('span.next-step__minor').text).to eq('Reminded 7 Oct')
      expect(actions(page)).not_to include('Remind them')
    end

    it 'sends a Scottish requester to a review first' do
      request = request_sent(tags: 'scotland')
      page = next_step(request, on: late)
      expect(page.at_css('section.next-step--act p').text).
        to include('In Scotland the next step is a review: ask by ')
      button = page.at_css('a.button')
      expect(button.text).to eq('Ask for a review')
      expect(button['href']).to include('internal_review=1')
      expect(page.at_css('button.next-step__link').text).to eq('Remind them')
    end
  end

  describe 'when something is asked of the requester' do
    it 'asks them to answer a request for clarification' do
      request = request_sent
      message = reply(request, 'waiting_clarification')
      page = next_step(request, on: start + 10.days)
      step = page.at_css('section.next-step--act')
      expect(step.at_css('h2').text).to eq('Clarification requested')
      expect(step.at_css('p').text).to start_with('They asked on 14 September.')
      button = step.at_css('a.button')
      expect([button.text, button['href']]).to eq(
        ['Reply to the authority',
         "/request/#{request.url_title}/followups/new/#{message.id}#followup"]
      )
      expect(step.at_css('details.next-step__status form.describe-state')).
        to be_present
    end

    it 'says a request couldn’t be delivered' do
      request = request_sent
      set_state(request, 'error_message')
      step = next_step(request, on: start + 2.days).
             at_css('section.next-step--act')
      expect(step.at_css('h2').text).to eq('Delivery problem')
      expect(step.at_css('p').text).to eq('Your request couldn’t be delivered.')
      expect(step.at_css('a.button').text).to eq('Contact us')
    end

    it 'names the decision and the last day to ask for a review, once they have written again' do
      request = request_sent
      reply(request, 'rejected')
      follow_up(request)
      action = action_for(request, on: start + 10.days)
      page = next_step(request, on: start + 10.days)
      step = page.at_css('section.next-step--act')
      expect(step.at_css('h2').text).
        to eq(InfoRequest::State.short_description('rejected'))
      expect(step.at_css('p').text).to eq(
        "Ask for an internal review by #{long(action.date)}. " \
        'After that, they can refuse to review it.'
      )
      expect(step.at_css('a.button')['href']).to include('internal_review=1')
      expect(actions(page)).
        to eq(['Ask for an internal review', 'Write a reply'])
      expect(step.at_css('.next-step__actions form.complete-form')).
        to be_present
    end

    it 'points to the regulator after a review' do
      request = request_sent
      reply(request, 'rejected')
      follow_up(request, :internal_review_request)
      reply(request, 'rejected', at: start + 20.days)
      action = action_for(request, on: start + 22.days)
      step = next_step(request, on: start + 22.days).
             at_css('section.next-step--act')
      expect(step.at_css('p').text).to eq(
        "The ICO asks for complaints within 6 weeks: by #{long(action.date)}."
      )
      button = step.at_css('a.button')
      expect(button.text).to eq('Complain to the ICO')
      expect(button['href']).to include(request.url_title)
    end
  end

  describe 'when the latest reply is the thing to look at' do
    it 'hands a refusal to the receipt, with the last day to ask for a review' do
      request = request_sent
      reply(request, 'rejected')
      action = action_for(request, on: start + 10.days)
      page = next_step(request, on: start + 10.days)
      receipt = page.at_css('section.receipt')
      expect(receipt['data-review-by']).to eq(action.date.to_s)
      expect(receipt['data-review-coming-up']).to eq('true')
      expect(receipt['data-change']).to eq('true')
      expect(receipt.at_css('form.complete-form')).to be_present
      expect(receipt.at_css('details.next-step__status')).to be_present
      expect(page.at_css('.next-step')).to be_nil
    end

    it 'hands over a reply nobody has answered for, which can’t be marked complete yet' do
      request = request_sent
      travel_to(start + 7.days) do
        AttachmentFixtures.deliver(request, [], text: "Here is our answer.\n")
      end
      receipt = next_step(request, on: start + 10.days).
                at_css('section.receipt')
      expect(receipt['data-review-by']).to be_present
      expect(receipt['data-review-coming-up']).to eq('true')
      expect(receipt.at_css('form.complete-form')).to be_nil
    end

    it 'hands over a reply that has only just come, with no review date yet' do
      request = request_sent
      reply(request, 'waiting_response')
      receipt = next_step(request, on: start + 10.days, arrived: true).
                at_css('section.receipt')
      expect(receipt['data-arrived']).to eq('true')
      expect(receipt['data-review-by']).to eq('')
      expect(receipt['data-review-coming-up']).to eq('false')
    end
  end

  describe 'when nothing more is expected' do
    it 'says when it was marked complete, and offers to reopen it' do
      request = request_sent
      reply(request, 'successful')
      travel_to(start + 8.days) do
        Deadlines::Closure.close!(
          request.reload,
          user: user,
          final_state: 'successful',
          last_event_id: request.info_request_events.maximum(:id)
        )
      end
      page = next_step(request, on: start + 10.days)
      step = page.at_css('section.next-step--done')
      expect(step.at_css('.receipt__kicker').text).
        to eq('Marked complete 15 Sep')
      expect(step.at_css('h2').text).
        to eq(InfoRequest::State.short_description('successful'))
      expect(step.at_css('form')['action']).
        to eq("/deadlines/#{request.id}/reopen")
      expect(actions(page)).to eq(['Reopen', 'Write a reply'])
      expect(page.at_css('section.receipt')).to be_nil
    end

    it 'gives a withdrawn request its status and a way to write' do
      request = request_sent
      set_state(request, 'user_withdrawn')
      page = next_step(request, on: start + 2.days)
      step = page.at_css('section.next-step--done')
      expect(step.at_css('h2').text).
        to eq(InfoRequest::State.short_description('user_withdrawn'))
      expect(actions(page)).to eq(['Send a followup'])
      expect(step.at_css('details.next-step__status')).to be_present
    end

    it 'has no status form for someone who may not set the status' do
      request = request_sent
      set_state(request, 'user_withdrawn')
      page = next_step(request, on: start + 2.days, owner: false)
      expect(page.at_css('section.next-step--done')).to be_present
      expect(page.at_css('details.next-step__status')).to be_nil
    end
  end
end
