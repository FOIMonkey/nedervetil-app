require 'spec_helper'

RSpec.describe 'Request journey queries', feature: :alaveteli_pro do
  include_context 'with incoming attention off'

  let(:owner) {
    FactoryBot.create(:user, name: 'Rowan Requester', trusted: true)
  }

  def page
    Nokogiri::HTML(response.body)
  end

  def names
    page.css('.authority-results__name').map(&:text)
  end

  def statements
    sql = []
    callback = ->(*args) {
      event = args.last
      sql << event[:sql] unless event[:name] == 'SCHEMA'
    }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    sql
  end

  it 'leaves out bodies that can’t be asked before taking the first twenty by name' do
    bodies = (1..25).map do |number|
      unaskable = case number
                  when 1..3 then { tag_string: 'defunct' }
                  when 4..6 then { tag_string: 'not_apply' }
                  when 7..9 then { request_email: '' }
                  when 10..12 then { request_email: 'blank' }
                  else {}
                  end
      FactoryBot.create(:public_body,
                        name: format('Quillmoor %02d District Council', number),
                        **unaskable)
    end
    sign_in(owner)
    get new_alaveteli_pro_info_request_path(step: 'who', query: 'Quillmoor')
    expect(names).to eq(bodies.last(13).map(&:name))
  end

  it 'filters by nation with the other nations’ tags, whichever nation is chosen' do
    { 'England' => 'local_council',
      'Scotland' => 'scotland',
      'Wales' => 'wales',
      'Ulster' => 'northern_ireland' }.each do |place, tag|
      FactoryBot.create(:public_body, name: "Quillmoor #{place} Council",
                                      tag_string: tag)
    end
    sign_in(owner)
    expected = { 'england' => 'England',
                 'scotland' => 'Scotland',
                 'wales' => 'Wales',
                 'northern_ireland' => 'Ulster' }
    expected.each do |nation, place|
      get new_alaveteli_pro_info_request_path(step: 'who',
                                              query: 'Quillmoor',
                                              journey: { nation: nation })
      expect(names).to eq(["Quillmoor #{place} Council"]), nation
    end
    expect(Topics::Topic::NATIONS.keys - ['england']).
      to eq(%w[scotland wales northern_ireland])
  end

  it 'counts a body with only a sic tag as Scottish' do
    FactoryBot.create(:public_body, name: 'Quillmoor Firth Council',
                                    tag_string: 'sic:quillmoor')
    FactoryBot.create(:public_body, name: 'Quillmoor Scotland Council',
                                    tag_string: 'scotland')
    FactoryBot.create(:public_body, name: 'Quillmoor England Council',
                                    tag_string: 'local_council')
    sign_in(owner)
    get new_alaveteli_pro_info_request_path(step: 'who',
                                            query: 'Quillmoor',
                                            journey: { nation: 'scotland' })
    expect(names).
      to eq(['Quillmoor Firth Council', 'Quillmoor Scotland Council'])
    get new_alaveteli_pro_info_request_path(step: 'who',
                                            query: 'Quillmoor',
                                            journey: { nation: 'england' })
    expect(names).to eq(['Quillmoor England Council'])
  end

  it 'works out the url_title when a request is saved, not when an unsaved one is given a title' do
    authority = FactoryBot.create(:public_body,
                                  name: 'Northmoor County Council')
    first = FactoryBot.create(:info_request, title: 'Quillmoor gritting routes')
    expect(first.url_title).to eq('quillmoor_gritting_routes')

    request = nil
    sql = statements {
      request = InfoRequest.new(title: 'Quillmoor gritting routes',
                                user: owner,
                                public_body: authority)
    }
    expect(sql.grep(/url_title ~/)).to eq([])
    expect([request.url_title, request.title_changed?]).to eq([nil, true])
    expect(FactoryBot.create(:info_request,
                             title: 'Quillmoor gritting routes').url_title).
      to eq('quillmoor_gritting_routes_2')

    first.title = 'Quillmoor salt bins'
    expect(first.url_title).to eq('quillmoor_salt_bins')
  end

  it 'renders Write request and Check and send without scanning every request’s url_title' do
    authority = FactoryBot.create(:public_body,
                                  name: 'Northmoor County Council')
    sign_in(owner)
    draft = FactoryBot.create(
      :draft_info_request,
      user: owner, title: 'Gritting routes 2025', public_body: authority,
      body: "Dear Northmoor County Council,\n\nPlease provide the " \
            "routes.\n\nYours faithfully,\n\nRowan Requester"
    )
    sql = statements do
      get new_alaveteli_pro_info_request_path(draft_id: draft.id)
      expect(response).to have_http_status(:ok)
      get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
      expect(response).to have_http_status(:ok)
    end
    expect(sql.grep(/url_title ~/)).to eq([])
  end
end
