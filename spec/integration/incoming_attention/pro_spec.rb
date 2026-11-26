require 'spec_helper'

RSpec.describe 'Lean incoming attention in Pro' do
  include_context 'with lean attention predictions'
  before do
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    allow(AlaveteliFeatures.backend).
      to receive(:enabled?).with(:alaveteli_pro).and_return(true)
  end
  let(:user) {
    FactoryBot.create(:pro_user, trusted: true)
  }
  it 'puts a reply that needs attention in its pile and keeps the existing list routes' do
    request = FactoryBot.create(:info_request, user: user)
    review = lean_response(request, 'REVIEW')
    routine = lean_response(request, 'SKIP')
    request.create_or_update_request_summary
    sign_in(user)
    get '/pro/dashboard'
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    pile = page.at_css('[data-pile="needs"]')
    expect(pile.at_css('h2').text).to include('Needs you')
    expect(pile.at_css(
      "a[href='/request/#{request.url_title}']"
    ).text).to eq(request.title)
    expect(page.text).
      not_to include('Email delivery status',
                     'Mark reviewed',
                     'Inspect / review')
    get '/pro/info_requests'
    inbox = Nokogiri::HTML(response.body)
    # The pile's tab carries the count, so its heading doesn't repeat it.
    expect(inbox.at_css('[data-pile="needs"] h2').text.squish).
      to eq('Needs you')
    counts = IncomingAttention::Effective.counts(user)
    { 'needs_attention' => review,
      'routine_updates' => routine }.each do |bucket, reply|
      get '/pro/info_requests',
          params: { alaveteli_pro_request_filter: { filter: bucket } }
      expect(response).to have_http_status(:ok)
      listed = Nokogiri::HTML(response.body)
      expect(listed.css('[data-summary-id]').length).to eq(counts.fetch(bucket))
      expect(listed.at_css('.attention-request-group ' \
                           '.embargo-indicator').text.strip).to eq('Private')
      expect(listed.css('[data-message-id]').map { |node|
        node['data-message-id'].to_i
      }).to eq([reply.id])
      expect(listed.at_css("a[href$='#incoming-#{reply.id}']")).to be_present
      expect(listed.css('a[href^="/incoming_attention/"]')).to be_empty
    end
    expect(request.reload.awaiting_description).to eq(true)
  end

  it 'keeps provisional SKIP on the attention list and does not parse missing predictions on list pages' do
    request = FactoryBot.create(:info_request, user: user)
    provisional = lean_response(request, 'SKIP', verified: false)
    message = FactoryBot.create(:incoming_message,
                                :unparsed,
                                info_request: request)
    FactoryBot.create(:response_event, info_request: request,
                                       incoming_message: message)
    request.update!(awaiting_description: true)
    request.create_or_update_request_summary
    sign_in(user)
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'needs_attention' } }
    expect(response).to have_http_status(:ok)
    expect(message.reload[:last_parsed]).to be_nil
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("[data-message-id='#{provisional.id}']")).to be_present
    expect(page.at_css("[data-message-id='#{message.id}']")).to be_nil
  end

  it 'keeps the existing UI when the single flag is off' do
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    sign_in(user)
    get '/pro/dashboard'
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).css('[data-attention-bucket]')).
      to be_empty
  end

  it 'shows every checked unresolved reply in its own list with direct message links' do
    request = FactoryBot.create(:info_request, user: user)
    classified = lean_response(request, 'SKIP')
    request.set_described_state('waiting_response', user)
    attention = Array.new(5) { lean_response(request, 'REVIEW') }
    routine = Array.new(5) { lean_response(request, 'SKIP') }
    request.create_or_update_request_summary
    sign_in(user)
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'needs_attention' } }
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.css('[data-message-id]').map { |node|
      node['data-message-id'].to_i
    }).to match_array(attention.map(&:id))
    expect(page.at_css("a[href$='#incoming-#{attention.first.id}']")).
      to be_present
    expect(page.text).
      not_to include('Showing 6 of 10',
                     'All correspondence',
                     'Complete correspondence')
    expect(page.at_css('.request__title a')['href']).
      to eq("/request/#{request.url_title}")
    expect(page.css("[data-message-id='#{classified.id}']")).to be_empty
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'routine_updates' } }
    page = Nokogiri::HTML(response.body)
    expect(page.css('[data-message-id]').map { |node|
      node['data-message-id'].to_i
    }).to match_array(routine.map(&:id))
    expect(page.at_css("a[href$='#incoming-#{routine.last.id}']")).to be_present
    expect(IncomingAttention::Effective.counts(user)).
      to eq('needs_attention' => 5, 'routine_updates' => 5)
  end

  it 'excludes a reassigned private batch child from AI groups and counts' do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 1)
    child = batch.info_requests.first
    message = lean_response(child, 'REVIEW')
    child.update!(user: FactoryBot.create(:user))
    batch.create_or_update_request_summary
    expect(Ability.new(user).can?(:read, message.reload)).to eq(false)
    expect(IncomingAttention::Effective.counts(user)['needs_attention']).
      to eq(0)
    sign_in(user)
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'needs_attention' } }
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).css('[data-summary-id]')).to be_empty
  end

  it 'does not expose private attention lists to visitors or another owner' do
    request = FactoryBot.create(:info_request, user: user)
    lean_response(request, 'REVIEW')
    request.create_or_update_request_summary
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'needs_attention' } }
    expect(response).to have_http_status(:redirect)
    other = FactoryBot.create(:pro_user)
    post '/profile/sign_in', params: {
      user_signin: { email: other.email, password: 'jonespassword' }
    }
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'needs_attention' } }
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(request.title)
  end
  it 'holds unchecked replies out of activity, todo, counts and lists until completion' do
    target = FactoryBot.create(:info_request, user: user)
    message = lean_response(target)
    lean_prediction(message, 'SKIP', status: 'pending')
    target.create_or_update_request_summary
    sign_in(user)
    get '/pro/dashboard'
    expect(response).to have_http_status(:ok)
    dashboard = Nokogiri::HTML(response.body)
    expect(dashboard.at_css('[data-pile="needs"]')).to be_nil
    expect(
      dashboard.at_css("[data-pile='waiting'] [data-request-id='#{target.id}']")
    ).to be_present
    expect(dashboard.css("a[href$='#reply-#{message.id}']")).to be_empty
    expect(user.phase_counts['response_received']).to eq(0)
    expect(IncomingAttention::Effective.dashboard_status(target)).
      to eq('waiting_response')
    expect(target.calculate_status).to eq('waiting_classification')
    get '/pro/info_requests'
    expect(response.body).to include(target.title)
    expect(
      Nokogiri::HTML(response.body).css("[data-message-id='#{message.id}']")
    ).to be_empty
    lean_prediction(message, 'REVIEW')
    expect(user.phase_counts!['response_received']).to eq(1)
  end

  it 'counts batch attention replies and displays every routine reply openly' do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 3)
    first, second, third = batch.info_requests.to_a
    attention = [lean_response(first, 'REVIEW'), lean_response(second,
                                                               'REVIEW')]
    routine = lean_response(third, 'SKIP')
    batch.create_or_update_request_summary
    expect(IncomingAttention::Effective.counts(user)).
      to eq('needs_attention' => 2, 'routine_updates' => 1)
    sign_in(user)
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'needs_attention' } }
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.text).to include('Also 1 routine update')
    expect(page.css('.attention-replies [data-message-id]').map { |n|
                      n['data-message-id'].to_i
                    }).to match_array(attention.map(&:id))
    expect(page.css("[data-message-id='#{routine.id}']")).to be_empty
    expect(page.css('details.routine-updates,.batch-correspondence')).
      to be_empty
    expect(page.at_css('.request__title a')['href']).
      to eq(
        Rails.application.routes.url_helpers.info_request_batch_path(batch.id)
      )
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'routine_updates' } }
    page = Nokogiri::HTML(response.body)
    expect(page.text).to include('2 replies need attention')
    expect(page.css('div.routine-updates [data-message-id]').map { |n|
                      n['data-message-id'].to_i
                    }).to eq([routine.id])
  end

  it 'puts each request in one pile: a reply to read first, routine replies stay awaiting the authority' do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 3)
    first, second, third = batch.info_requests.to_a
    review = lean_response(first, 'REVIEW')
    acks = [lean_response(second, 'SKIP'), lean_response(third, 'SKIP')]
    single = FactoryBot.create(:info_request, user: user)
    lean_response(single, 'SKIP')
    [batch, single].each(&:create_or_update_request_summary)
    sign_in(user)
    get '/pro/dashboard'
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    needs = page.at_css('[data-pile="needs"]')
    expect(needs.css('[data-request-id]').map { |n|
      n['data-request-id'].to_i
    }).to eq([first.id])
    expect(needs.at_css(
      "a[href='/request/#{first.url_title}']"
    ).text).to eq(first.title)
    expect(needs.at_css('.pile__reason').text.squish).to eq('Replied')
    expect(page.at_css('.home-spots__urgent').text.squish).
      to eq("1 New reply From #{Deadlines::Overview.format_date(review.sent_at.to_date)}")
    waiting = page.at_css('[data-pile="waiting"]')
    expect(waiting.css('[data-request-id]').map { |n|
      n['data-request-id'].to_i
    }).to match_array([second.id, third.id, single.id])
    expect(page.css("[data-message-id='#{acks.first.id}']")).to be_empty
    expect(page.css('[data-request-id]').map { |n|
      n['data-request-id']
    }.tally.values.uniq).to eq([1])
  end

  it 'lists only statuses that have requests and marks the current list' do
    request = FactoryBot.create(:info_request, user: user)
    lean_response(request, 'REVIEW')
    request.create_or_update_request_summary
    sign_in(user)
    get '/pro/info_requests', params: {
      alaveteli_pro_request_filter: { filter: 'response_received' }
    }
    page = Nokogiri::HTML(response.body)
    phases = page.css('.dashboard-sub-folders ' \
                      '.dashboard-folder__name').map { |n| n.text.squish }
    expect(phases).to eq(['Response received 1'])
    expect(page.text).not_to include('Drafts')
    expect(page.at_css('[aria-current="page"]').text.squish).
      to eq('Response received 1')
    expect(page.at_css('.dashboard-sub-folders ' \
                       '.icon-standalone.icon_waiting_classification')).
      to be_present
  end

  it 'lists every request in the dashboard’s piles on the full request list, with the reply to read' do
    request = FactoryBot.create(:info_request, user: user)
    lean_response(request, 'REVIEW')
    lean_response(request, 'SKIP')
    request.create_or_update_request_summary
    sign_in(user)
    get '/pro/info_requests'
    page = Nokogiri::HTML(response.body)
    row = page.at_css("[data-pile='needs'] [data-request-id='#{request.id}']")
    expect(row.at_css('.pile__reason').text.squish).to eq('Replied')
    expect(row.at_css('a.pile__title')['href']).
      to eq("/request/#{request.url_title}")
    expect(page.at_css('.requests-piles a[aria-current="page"]').text.squish).
      to eq('All 1')
    expect(page.at_css('[data-summary-id], .dashboard-left-column')).to be_nil
  end
  it 'clears individual routine updates with Dismiss without changing status or other batch replies' do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 2)
    first, second = batch.info_requests.to_a
    dismissed = lean_response(first, 'SKIP')
    kept = lean_response(second, 'SKIP')
    [first, second].each { |target| IncomingAttention::Classification.apply(target.reload) }
    batch.create_or_update_request_summary
    status_before = first.reload.attributes
    events_before = first.info_request_events.pluck(:id,
                                                    :described_state,
                                                    :last_described_at)
    prediction_before = IncomingAttention::Prediction.for_message(dismissed).attributes
    sign_in(user)
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'routine_updates' } }
    page = Nokogiri::HTML(response.body)
    dismiss = page.css('form.routine-reply-dismiss').find { |form|
      form.at_css(
        'input[name="incoming_message_ids[]"]'
      )['value'].to_i == dismissed.id
    }
    expect(dismiss).to be_present
    expect(dismiss['method']).to eq('post')
    expect(dismiss.at_css('button')['aria-label']).
      to include(first.public_body.name)
    post dismiss['action'], params: {
      incoming_message_ids: [dismissed.id],
      incoming_attention_return: 'routine_updates'
    }
    expect(response).
      to redirect_to(
        '/pro/info_requests?alaveteli_pro_request_filter%5Bfilter%5D=' \
        'routine_updates'
      )
    expect(first.reload.attributes).to eq(status_before)
    expect(first.info_request_events.pluck(:id,
                                           :described_state,
                                           :last_described_at)).
      to eq(events_before)
    row = IncomingAttention::Prediction.for_message(dismissed)
    expect(row.human_reviewed_at).to be_present
    expect(row.attributes.except('human_reviewed_at', 'updated_at')).
      to eq(prediction_before.except('human_reviewed_at', 'updated_at'))
    expect(IncomingAttention::Effective.counts(user)).
      to eq('needs_attention' => 0, 'routine_updates' => 1)
    expect(IncomingAttention::Effective.reviewed?(dismissed.reload)).to be true
    get "/request/#{first.url_title}"
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("#incoming-#{dismissed.id}")).
      to be_present
    expect(
      IncomingAttention::Effective.routine(IncomingMessage.where(id: kept.id))
    ).to exist
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'routine_updates' } }
    page = Nokogiri::HTML(response.body)
    expect(page.css('[data-message-id]').map { |node|
      node['data-message-id'].to_i
    }).to eq([kept.id])
    dismiss = page.at_css('form.routine-reply-dismiss')
    expect(page.at_css('.requests__folder-hint').text).
      to include('Dismiss an update to remove it from this list.')
    expect(page.at_css('.routine-reply')).to be_present
    expect(dismiss.at_css('input[name="incoming_attention_return"]')['value']).
      to eq('routine_updates')
    post dismiss['action'], params: {
      incoming_message_ids: [kept.id],
      incoming_attention_return: 'routine_updates'
    }
    expect(response).
      to redirect_to(
        '/pro/info_requests?alaveteli_pro_request_filter%5Bfilter%5D=' \
        'routine_updates'
      )
    expect(IncomingAttention::Effective.counts(user)['routine_updates']).
      to eq(0)
    later = lean_response(first, 'SKIP')
    IncomingAttention::Classification.apply(first.reload)
    expect(first.reload.awaiting_description?).to be false
    expect(
      IncomingAttention::Effective.routine(IncomingMessage.where(id: later.id))
    ).to exist
  end

  it 'lists routine updates for a suspended requester without Dismiss' do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 2)
    first, second = batch.info_requests.to_a
    lean_response(first, 'SKIP')
    lean_response(second, 'SKIP')
    [first, second].each { |target| IncomingAttention::Classification.apply(target.reload) }
    batch.create_or_update_request_summary
    user.update!(ban_text: 'Spam')
    sign_in(user)
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'routine_updates' } }
    page = Nokogiri::HTML(response.body)
    expect(page.css('.routine-reply').size).to eq(2)
    expect(page.css('form.routine-reply-dismiss')).to be_empty
    expect(page.css('form.routine-replies-dismiss-all')).to be_empty
  end

  it 'dismisses every routine child across a batch in one POST without changing core state' do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 3)
    children = batch.info_requests.order(:id).to_a
    messages = children.map { |target| lean_response(target, 'SKIP') }
    children.each { |target| IncomingAttention::Classification.apply(target.reload) }
    batch.create_or_update_request_summary
    before = children.map { |target|
      [target.reload.attributes, target.info_request_events.pluck(
        :id,
        :described_state,
        :last_described_at
      )]
    }
    sign_in(user)
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'routine_updates' } }
    button = Nokogiri::HTML(response.body).at_css('form.routine-replies-dismiss-all')
    expect(button.at_css('button').text).to eq('Dismiss all 3')
    expect(button.at_css('button')['aria-label']).
      to eq("Dismiss all 3 routine updates for #{batch.title}")
    expect(button.css('input[name="incoming_message_ids[]"]').map { |n|
      n['value'].to_i
    }).to match_array(messages.map(&:id))
    post button['action'],
         params: { incoming_message_ids: messages.map(&:id),
                   incoming_attention_return: 'routine_updates' }
    expect(response).
      to redirect_to(
        '/pro/info_requests?alaveteli_pro_request_filter%5Bfilter%5D=' \
        'routine_updates'
      )
    expect(IncomingAttention::Prediction.where(
      incoming_message_id: messages.map(&:id)
    ).where(human_reviewed_at: nil)).not_to exist
    expect(IncomingAttention::Effective.counts(user)['routine_updates']).
      to eq(0)
    expect(children.map { |target|
      [target.reload.attributes, target.info_request_events.pluck(
        :id,
        :described_state,
        :last_described_at
      )]
    }).to eq(before)
    expect(IncomingMessage.where(id: messages.map(&:id)).count).to eq(3)
  end

  it 'rejects another batch and unbatched sibling IDs without partially dismissing' do
    target = FactoryBot.create(:info_request, user: user)
    own = lean_response(target, 'SKIP')
    outsiders = [FactoryBot.create(:info_request, user: user),
                 FactoryBot.create(:info_request_batch,
                                   :sent,
                                   user: user,
                                   public_body_count: 1).info_requests.first]
    sign_in(user)
    outsiders.each do |other|
      reply = lean_response(other, 'SKIP')
      post "/request/#{target.url_title}/attention_dismissal", params: {
        incoming_message_ids: [own.id, reply.id]
      }
      expect(response).to have_http_status(:bad_request)
      expect(IncomingAttention::Prediction.where(
        incoming_message_id: [own.id, reply.id]
      ).where.not(human_reviewed_at: nil)).not_to exist
    end
  end

  it 'rejects a transferred sibling owner before any dismissal is written',
     local_requests: false do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 2)
    first, second = batch.info_requests.order(:id).to_a
    messages = [lean_response(first, 'SKIP'), lean_response(second, 'SKIP')]
    sign_in(user)
    allow(InfoRequest).
      to receive(:transaction).and_wrap_original do |original, *args, &block|
      second.update_columns(user_id: FactoryBot.create(:user).id)
      original.call(*args, &block)
    end
    post "/request/#{first.url_title}/attention_dismissal", params: {
      incoming_message_ids: messages.map(&:id)
    }
    expect(response).to have_http_status(:forbidden)
    expect(IncomingAttention::Prediction.where(
      incoming_message_id: messages.map(&:id)
    ).where.not(human_reviewed_at: nil)).not_to exist
  end

  it 'rechecks read permission on every batch message before writing ' \
     'any marker', local_requests: false do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 2)
    first, second = batch.info_requests.order(:id).to_a
    messages = [lean_response(first, 'SKIP'), lean_response(second, 'SKIP')]
    sign_in(user)
    allow(InfoRequest).
      to receive(:transaction).and_wrap_original do |original, *args, &block|
      messages.last.update_columns(prominence: 'hidden')
      original.call(*args, &block)
    end
    post "/request/#{first.url_title}/attention_dismissal", params: {
      incoming_message_ids: messages.map(&:id)
    }
    expect(response).to have_http_status(:forbidden)
    expect(IncomingAttention::Prediction.where(
      incoming_message_id: messages.map(&:id)
    ).where.not(human_reviewed_at: nil)).not_to exist
  end

  it 'silently skips attention replies that changed since the routine list was loaded' do
    target = FactoryBot.create(:info_request, user: user)
    routine = lean_response(target, 'SKIP')
    changed = lean_response(target, 'SKIP')
    sign_in(user)
    IncomingAttention::Prediction.for_message(changed).
      update!(attention_override: 'attention')
    post "/request/#{target.url_title}/attention_dismissal",
         params: { incoming_message_ids: [routine.id, changed.id],
                   incoming_attention_return: 'routine_updates' }
    expect(response).
      to redirect_to(
        '/pro/info_requests?alaveteli_pro_request_filter%5Bfilter%5D=' \
        'routine_updates'
      )
    expect(
      IncomingAttention::Prediction.for_message(routine).human_reviewed_at
    ).to be_present
    expect(
      IncomingAttention::Prediction.for_message(changed).human_reviewed_at
    ).to be_nil
  end

  it 'rejects more than 200 IDs and malformed input without making any change' do
    target = FactoryBot.create(:info_request, user: user)
    message = lean_response(target, 'SKIP')
    sign_in(user)
    [Array.new(201, message.id), message.id.to_s,
     [],
     ['bogus'],
     [0],
     [message.id, 99999999]].each do |ids|
      post "/request/#{target.url_title}/attention_dismissal", params: {
        incoming_message_ids: ids
      }
      expect(response).to have_http_status(:bad_request)
      expect(
        IncomingAttention::Prediction.for_message(message).human_reviewed_at
      ).to be_nil
    end
  end

  it 'shows nobody signed in no requests, whatever scope is given' do
    FactoryBot.create(:info_request, user: user)
    expect(IncomingAttention::Effective.visible_requests(nil)).to be_empty
    expect(IncomingAttention::Effective.visible_requests(nil, InfoRequest.all)).
      to be_empty
  end

  it 'works the attention decisions out once for a page of the request list' do
    request = FactoryBot.create(:info_request, user: user)
    lean_response(request, 'REVIEW')
    requests = IncomingAttention::Effective.visible_requests(user)
    statements = 0
    counter = ->(*, payload) {
      if payload[:sql].include?('incoming_attention_predictions')
        statements += 1
      end
    }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      2.times { IncomingAttention::Effective.ready_request_ids(requests) }
    end
    without = statements
    statements = 0
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      Current.memoising do
        2.times { expect(IncomingAttention::Effective.ready_request_ids(requests)).to eq([request.id]) }
      end
    end

    expect(statements * 2).to eq(without)
  end

  it 'decides once which of the user’s requests need attention for the sidebar, the counts and the list' do
    requests = Array.new(2) { FactoryBot.create(:info_request, user: user) }
    requests.each { |request|
      lean_response(request, 'REVIEW')
      request.create_or_update_request_summary
    }
    sign_in(user)
    whole_account = 0
    allow(IncomingAttention::Effective).
      to receive(:dashboard_attention).and_wrap_original do |original, *args|
      if args.first&.to_sql.to_s.include?(
        %("info_requests"."user_id" = #{user.id})
      )
        whole_account += 1
      end
      original.call(*args)
    end
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'needs_attention' } }
    page = Nokogiri::HTML(response.body)

    expect(whole_account).to eq(1)
    expect(page.at_css(
      '[data-attention-bucket="needs_attention"]'
    )['data-count'].to_i).
      to eq(2)
    expect(page.css('[data-summary-id]').size).to eq(2)
  end

  it 'counts and lists only an admin’s own requests, whatever other requesters have' do
    admin = FactoryBot.create(:pro_user, :admin, trusted: true)
    own = FactoryBot.create(:info_request, user: admin)
    lean_response(own, 'REVIEW')
    own.create_or_update_request_summary
    others = ->(count) {
      count.times {
        lean_response(FactoryBot.create(:info_request,
                                        user: FactoryBot.create(:user)),
                      'REVIEW')
      }
    }
    instantiated = -> do
      messages = 0
      counter = ->(*, payload) {
        if payload[:class_name] == 'IncomingMessage'
          messages += payload[:record_count]
        end
      }
      ActiveSupport::Notifications.subscribed(counter,
                                              'instantiation.active_record') do
        get '/pro/info_requests', params: {
          alaveteli_pro_request_filter: { filter: 'needs_attention' }
        }
      end
      messages
    end
    others.call(2)
    sign_in(admin)
    few = instantiated.call
    others.call(6)
    many = instantiated.call
    page = Nokogiri::HTML(response.body)

    expect(
      page.at_css('[data-attention-bucket="needs_attention"]')['data-count']
    ).to eq('1')
    expect(page.css('[data-summary-id]').size).to eq(1)
    expect(IncomingAttention::Effective.counts(admin)).
      to eq('needs_attention' => 1, 'routine_updates' => 0)
    expect(many).to eq(few)
  end

  it 'works out the attention list data only where a core list filter shows it' do
    request = FactoryBot.create(:info_request, user: user)
    lean_response(request, 'REVIEW')
    request.create_or_update_request_summary
    sign_in(user)
    allow(IncomingAttention::Effective).to receive(:page_data).and_call_original
    get '/pro/info_requests'
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'draft' } }
    expect(IncomingAttention::Effective).not_to have_received(:page_data)
    get '/pro/info_requests',
        params: { alaveteli_pro_request_filter: { filter: 'needs_attention' } }
    expect(IncomingAttention::Effective).to have_received(:page_data).once
  end

  it 'loads the drafts’ authorities with their names in one go' do
    sign_in(user)
    translations = -> do
      statements = 0
      counter = ->(*, payload) {
        if payload[:sql].include?('public_body_translations') &&
           !payload[:cached]
          statements += 1
        end
      }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        get '/pro/info_requests',
            params: { alaveteli_pro_request_filter: { filter: 'draft' } }
      end
      statements
    end
    2.times { FactoryBot.create(:draft_info_request, user: user) }
    few = translations.call
    4.times { FactoryBot.create(:draft_info_request, user: user) }
    expect(translations.call).to eq(few)
    expect(Nokogiri::HTML(response.body).css('.pile__authority').size).to eq(6)
  end

  it 'requires the feature to remain enabled at dismissal time',
     local_requests: false do
    target = FactoryBot.create(:info_request, user: user)
    message = lean_response(target, 'SKIP')
    row = IncomingAttention::Prediction.for_message(message)
    sign_in(user)
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    post "/request/#{target.url_title}/attention_dismissal", params: {
      incoming_message_ids: [message.id]
    }
    expect(response).to have_http_status(:forbidden)
    expect(row.reload.human_reviewed_at).to be_nil
  end
end
