require 'spec_helper'

RSpec.describe 'The sample data', feature: :alaveteli_pro do
  # One example, so everything it makes is rolled back with it.
  it 'loads, and its pages work for visitors, the requester and an admin' do
    # The test database holds upstream's fixtures. Make room for the two names
    # the sample data shares with them, and let it load beside them.
    InfoRequest.where(url_title: 'are_you_really_a_badger').
      update_all(url_title: 'fixture_badger')
    User.where(email: 'annie@localhost').
      update_all(email: 'annie-fixture@localhost')
    allow(SampleData).to receive(:data?).and_return(false)
    # The suite's topics are the sample's, so it leaves them as they are.
    expect { SampleData.load!(out: StringIO.new) }.
      not_to change(TopicChange, :count)

    year = Time.zone.today.year
    expect(Holiday.where(description: 'Christmas Day').pluck(:day)).
      to include(*(year..(year + 2)).map { Date.new(_1, 12, 25) })

    requester = User.find_by!(email: 'requester@example.org')
    admin = User.find_by!(email: 'admin@example.org')
    annie = User.find_by!(email: 'annie@localhost')
    states = requester.info_requests.to_h do |request|
      [request.title, request.calculate_status]
    end
    expect(states).to include(
      'Fly-tipping reports and fines in 2025' => 'waiting_classification',
      'Home to school transport for pupils with SEND' =>
        'waiting_response_overdue',
      'Patients cared for in corridors' => 'waiting_clarification',
      'Public toilets opened and closed since 2020' => 'successful',
      'Streetlight repair times' => 'partially_successful',
      'Use of live facial recognition' => 'internal_review',
      'Waiting times for student counselling' => 'rejected',
      'Guidance on damp and mould in rented homes' => 'user_withdrawn',
      'Ferry service cancellations in 2025' => 'waiting_response',
      'Air quality monitoring results for 2025' => 'waiting_response',
      'Damp and mould complaints in temporary accommodation' =>
        'partially_successful',
      'Are you really a badger?' => 'waiting_response'
    )
    expect(requester.info_requests.count).to eq(14)
    expect(
      Disclosures::Suggestion.where(
        incoming_message_id: IncomingMessage.
          where(info_request_id: requester.info_requests.select(:id)).
          select(:id)
      )
    ).to exist
    expect(requester.info_requests.pluck(:prominence).uniq).
      to eq(['requester_only'])
    expect(requester.info_request_batches.count).to eq(1)
    expect(requester.draft_info_requests.count).to eq(1)

    badger = InfoRequest.find_by!(url_title: 'are_you_really_a_badger')
    expect(badger.user).to eq(requester)
    expect(badger.outgoing_messages.first.body).
      to eq('Is it true that you are really a badger, in fact?')

    expect(admin).to be_is_admin
    expect(annie.roles.pluck(:name)).to contain_exactly('admin')
    expect(Deadlines::Reminder.where(user: requester).count).to eq(1)
    expect(Deadlines::Adjustment.where(user: requester).pluck(:reason)).
      to eq(['eir_extension'])
    expect(Deadlines::Closure.where(user: requester).pluck(:final_state)).
      to eq(['user_withdrawn'])
    expect(AttachmentManagement::Revision.where(user: requester).
           pluck(:status).uniq).to eq(['applied'])
    expect(RequestLimits.refusal(requester, :request)).to be_nil

    documents = Disclosures::Document.where(state: 'published').
                joins(:info_request).
                where(info_requests: { user_id: requester.id })
    expect(documents.count).to eq(4)
    letter = documents.find_by!(title: 'Streetlight repair times in 2025')
    expect(letter.foi_attachment.applied_revisions.first.kind).
      to eq('pdf_redaction')

    routine = IncomingAttention::Prediction.
              where(info_request: requester.info_requests,
                    route: 'SKIP', status: 'complete')
    expect(routine.count).to eq(4)
    outcomes = IncomingAttention::Prediction.
               where(info_request: requester.info_requests).
               where.not(outcome_call: nil)
    expect(outcomes.pluck(:outcome_call)).
      to contain_exactly('all', 'some', 'not_held')
    in_review = Disclosures::Document.
                where(id: Disclosures::ReviewSubmission.pending_document_ids)
    expect(in_review.pluck(:title)).
      to include('Student counselling waiting times')

    larkhollow = PublicBody.find_by!(name: 'Larkhollow District Council')
    suggested = RequestJourney::Suggestions.new(larkhollow, 'Public toilets')
    expect(suggested.documents.map(&:title)).
      to include('Public toilets run by the council since 2020')

    kilbranach = PublicBody.find_by!(name: 'Kilbranach Council')
    expect(FoiStatistics.for_body(kilbranach).current).to be(true)
    wrenford = PublicBody.find_by!(name: 'Wrenford County Council')

    [
      '/', '/body', "/body/#{wrenford.url_name}",
      "/body/#{wrenford.url_name}/foi-record",
      "/body/#{kilbranach.url_name}/foi-record",
      "/body/#{wrenford.url_name}/documents",
      '/groups',
      *SampleData::Dataset::GROUPS.map { |*, tag, _| "/groups/#{tag}" },
      '/groups/wrenford/documents', '/groups/kilbranach/foi_record',
      '/documents',
      *documents.map { |document| "/documents/#{document.to_param}" }
    ].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
    end
    ['/topics', *Topics::Topic.all.map { |topic| "/topics/#{topic.slug}" },
     "/body/#{larkhollow.url_name}"].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
    end
    get '/groups/local_council'
    expect(response.body).to include('Who does what')

    hidden =
      begin
        get "/request/#{badger.url_title}"
        response.status
      rescue ApplicationController::RouteNotFound
        404
      end
    expect(hidden).to eq(404)

    sign_in(requester)
    get '/pro/dashboard'
    expect(response).to have_http_status(:ok)
    requester.info_requests.each do |request|
      get "/request/#{request.url_title}"
      expect(response).to have_http_status(:ok), request.title
      expect(response.body).to include(CGI.escapeHTML(request.title))
    end
    get info_request_batch_path(requester.info_request_batches.first)
    follow_redirect! while response.redirect?
    expect(response).to have_http_status(:ok)
    get '/documents/yours'
    expect(response).to have_http_status(:ok)

    sign_in(admin)
    ['/admin', "/admin/requests/#{badger.id}", '/documents/review',
     '/admin/authority_groups', '/admin/authority_pages'].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
    end
    get '/documents/review'
    expect(response.body).to include('Student counselling waiting times')
    counselling = in_review.find_by!(title: 'Student counselling waiting times')
    get admin_disclosure_manage_document_path(counselling)
    expect(response).to have_http_status(:ok)
    expect(response.body).
      to include(admin_disclosure_document_page_path(counselling, page: 1))
    expect(response.body).
      to include(admin_disclosure_download_document_path(counselling))
    get admin_disclosure_document_page_path(counselling, page: 1)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('image/png')
    get admin_disclosure_download_document_path(counselling)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/pdf')
    expect do
      get disclosure_document_download_path(counselling)
      expect(response).to have_http_status(:not_found)
    rescue ActiveRecord::RecordNotFound
      true
    end.not_to raise_error
  end
end
