require 'spec_helper'

RSpec.describe 'Authority pages fed by data' do
  include DisclosuresHelpers
  include ActiveSupport::Testing::TimeHelpers
  include_context 'with production error pages'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:glenmoor) do
    FactoryBot.create(:public_body,
                      name: 'Glenmoor Council',
                      home_page: 'https://glenmoor.example.invalid',
                      tag_string: 'local_council scottish_council scotland ' \
                                  'sic:glenmoor gss:S12000049')
  end
  let(:westshire) do
    FactoryBot.create(:public_body,
                      name: 'Westshire County Council',
                      tag_string: 'local_council county_council england')
  end
  let(:ashdown) do
    FactoryBot.create(:public_body,
                      name: 'Ashdown District Council',
                      tag_string: 'local_council district_council england ' \
                                  "gss:E07000200 county:#{westshire.url_name}")
  end
  let(:counts) do
    { 'requests' => 1200, 'on_time' => 900, 'late' => 250, 'no_reply' => 50,
      'full' => 400, 'some' => 300, 'none' => 200, 'not_held' => 100,
      'neither_confirm_nor_deny' => 20, 'refused' => 30 }
  end

  def feed(key)
    AuthorityFeeds::Feed.find_by!(key: key)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def texts(selector)
    page.css(selector).map { |node| node.text.squish }
  end

  def statistics(body, years, scotland: true, note: nil)
    rows = years.flat_map do |year|
      counts.map do |metric, value|
        { scope_key: "body:#{body.id}", public_body_id: body.id,
          period: year, metric: metric, value: value }
      end +
        (if scotland
           counts.map do |metric, value|
             { scope_key: 'sector:scotland', public_body_id: nil,
               period: year, metric: metric, value: value * 50 }
           end
         else
           []
         end)
    end
    AuthorityFeeds::Store.new(feed('sic_statistics')).
      save_figures(rows, notes: note ? { body.id => note } : {})
  end

  def decisions(body, key, rows)
    feed = feed(key)
    AuthorityFeeds::Store.new(feed).save_items(
      rows.map do |reference, on, outcome, title|
        AuthorityFeeds::Decisions.row(
          feed: feed, public_body_id: body.id, authority_name: body.name,
          decided_on: on, reference: reference, title: title, outcome: outcome,
          url: "https://decisions.example.invalid/#{reference.parameterize}"
        )
      end
    )
    feed.update!(checked_at: Time.current)
  end

  def release(body, title, on)
    AuthorityGroups::ExternalRelease.create!(
      public_body: body, title: title, released_on: on,
      url: "https://log.example.invalid/#{title.parameterize}"
    )
  end

  def note(text, style:, tag: nil, body: nil)
    Note.create!(notable_tag: tag, notable: body, style: style,
                 body: (text if style == 'original'),
                 rich_body: (text unless style == 'original'))
  end

  around do |example|
    travel_to(Time.zone.local(2026, 10, 23, 12)) { example.run }
  end

  describe 'the Overview' do
    it 'puts up-to-date figures at the top, with tabs, and leaves the panel out' do
      statistics(glenmoor, %w[2024-25 2025-26])
      decisions(glenmoor, 'sic_decisions',
                [['003/2026', Date.new(2026, 1, 13), 'For applicant',
                  'Whether request was repeated'],
                 ['250/2025', Date.new(2025, 10, 9), 'Partially upheld',
                  'Environmental levy'],
                 ['101/2010', Date.new(2010, 5, 2), 'For authority',
                  'An old one']])
      release(glenmoor, 'Bin hub pilots', Date.new(2026, 10, 21))

      get "/body/#{glenmoor.url_name}"
      expect(page.css('#content h1').size).to eq(1)
      expect(texts('.body-tabs a')).
        to eq(['Overview', 'Documents', 'FOI record'])
      expect(page.at_css('.body-tabs a[aria-current="page"]').text).
        to eq('Overview')
      expect(texts('.spotlights li')).
        to eq(['75% Answered on time, 2025–26', '1,200 Requests, 2025–26',
               '3 Commissioner decisions Since 2010'])
      expect(page.css('.spotlights a').map { |a| a['href'] }.uniq).
        to eq(["/body/#{glenmoor.url_name}/foi-record"])
      expect(page.at_css('.foi-record')).to be_nil
      expect(texts('.foi-decisions li .foi-decisions__outcome')).
        to eq(['Upheld', 'Partly upheld', 'Not upheld'])
      expect(page.at_css('#body-decisions').text).
        to eq('Commissioner decisions')
      expect(texts('#body-releases')).to eq(['Recent releases'])
      expect(texts('.page-band__summary')).to eq(['Scottish council'])
      expect(texts('.page-band__actions a').last).
        to eq('Visit website (another site)')
    end

    it 'keeps out-of-date figures in the sidebar, labelled with their year, and never at the top' do
      statistics(glenmoor, %w[2022-23 2023-24],
                 note: 'Figures include the licensing board')
      get "/body/#{glenmoor.url_name}"
      expect(page.at_css('.spotlights')).to be_nil
      expect(page.at_css('.foi-record h2').text).to eq('FOI record, 2023–24')
      expect(page.at_css('.foi-record__source').text).
        to start_with('Figures include the licensing board.')
    end

    it 'shows no figures for too few requests, and no tab row for an authority with nothing but tags' do
      counts['requests'] = FoiStatistics::MIN_REQUESTS - 1
      statistics(glenmoor, %w[2025-26])
      get "/body/#{glenmoor.url_name}"
      expect(page.at_css('.spotlights')).to be_nil
      expect(page.at_css('.foi-record')).to be_nil
      expect(page.at_css('.body-tabs')).to be_nil

      get "/body/#{ashdown.url_name}"
      expect(page.at_css('.body-tabs')).to be_nil
      expect(page.at_css('.spotlights')).to be_nil
      expect(page.at_css('.body-holds__usually').text).
        to eq('Usually, for a district council in England:')
      expect(texts('.useful-links li a')).
        to include('Local statistics (another site)')
      expect(page.at_css(
               '.useful-links a[href="https://www.ons.gov.uk/explore-local-statistics/areas/E07000200"]'
             )).to be_present
    end

    it 'leaves out what an admin unticked, and places notes by colour' do
      note('Roads and social care are run by {county}.',
           style: 'yellow', tag: 'district_council')
      note('<h1>20 working days</h1>' \
           '<div>They must reply within 20 working days.</div>',
           style: 'blue', tag: 'england')
      note('Closed in 2021.', style: 'red', body: ashdown)
      get "/body/#{ashdown.url_name}"
      expect(texts('.body-holds__what')).to include('Food hygiene inspections')
      expect(page.at_css('.holds-caveats li').text.squish).
        to eq('Roads and social care are run by Westshire County Council.')
      expect(page.at_css('.holds-caveats a')['href']).
        to eq("/body/#{westshire.url_name}")
      expect(page.at_css('.guide-card h2').text).to eq('20 working days')
      expect(page.at_css('.body-warning').text.squish).to eq('Closed in 2021.')

      ashdown.update!(
        tag_string: "#{ashdown.tag_string} holds_not:food_hygiene",
        last_edit_editor: 'test', last_edit_comment: 'test'
      )
      get "/body/#{ashdown.url_name}"
      expect(texts('.body-holds__what')).
        not_to include('Food hygiene inspections')

      ashdown.update!(tag_string: 'local_council district_council england',
                      last_edit_editor: 'test', last_edit_comment: 'test')
      get "/body/#{ashdown.url_name}"
      expect(page.at_css('.holds-caveats')).to be_nil
    end

    it 'links to their spending data from a spending: tag, as it is' do
      glenmoor.update!(tag_string: "#{glenmoor.tag_string} spending:https://glenmoor.example.invalid/spend?year=2026",
                       last_edit_editor: 'test', last_edit_comment: 'test')
      get "/body/#{glenmoor.url_name}"
      link = page.css('.useful-links a').
        find { |a| a.text.start_with?('Spending data') }
      expect(link['href']).to eq('https://glenmoor.example.invalid/spend?year=2026')
      expect(page.at_css('.body-tabs')).to be_nil
    end

    it 'says how old a quiet list is' do
      release(glenmoor, 'Old release', Date.new(2024, 6, 18))
      get "/body/#{glenmoor.url_name}"
      expect(page.at_css('#body-releases').text).to eq('Releases')
      expect(page.at_css('.body-elsewhere .group-page__source').text).
        to eq('From their disclosure log. Newest from June 2024.')
    end
  end

  describe 'the tabs' do
    it 'shows the FOI record: the year beside Scotland, every year, and every decision' do
      statistics(glenmoor, %w[2023-24 2024-25 2025-26])
      decisions(glenmoor, 'sic_decisions', (1..25).map do |n|
        [format('%03d/2026', n), Date.new(2026, 1, 1) + n, 'For applicant',
         "Decision #{n}"]
      end)
      get "/body/#{glenmoor.url_name}/foi-record"
      expect(response).to have_http_status(:ok)
      expect(page.at_css('.body-tabs a[aria-current="page"]').text).
        to eq('FOI record')
      expect(texts('.foi-table--headline thead th')).
        to eq(['Figure', 'Glenmoor Council', 'All Scottish authorities'])
      expect(page.css('.foi-trend svg rect.trend__bar').size).to eq(3)
      expect(page.css('.foi-trend svg rect.trend__bar--latest').size).to eq(1)
      expect(page.css('.foi-decisions li').size).to eq(20)
      expect(page.at_css('.pagination, .groups-pager')).to be_present
    end

    it 'sends an empty tab to the Overview' do
      %w[documents foi-record].each do |tab|
        get "/body/#{ashdown.url_name}/#{tab}"
        expect(response).to redirect_to("/body/#{ashdown.url_name}")
      end
    end

    it 'lists releases on the Documents tab, searchable by title' do
      release(glenmoor, 'Bin hub pilots', Date.new(2026, 10, 21))
      release(glenmoor, 'Parking fines by ward', Date.new(2026, 10, 2))
      get "/body/#{glenmoor.url_name}/documents"
      expect(texts('.body-elsewhere .group-page__external')).
        to eq(['Bin hub pilots (another site)',
               'Parking fines by ward (another site)'])
      get "/body/#{glenmoor.url_name}/documents", params: { q: 'parking' }
      expect(texts('.body-elsewhere .group-page__external')).
        to eq(['Parking fines by ward (another site)'])
    end
  end

  describe 'a group page' do
    let(:root) { PublicBody.category_root }
    let(:places) do
      Category.create!(title: 'Place', description: '', parent_ids: [root.id])
    end
    let(:types) do
      Category.create!(title: 'Type', description: '', parent_ids: [root.id])
    end
    let!(:scotland) do
      Category.create!(title: 'Scotland', description: '',
                       category_tag: 'scotland', parent_ids: [places.id])
    end
    let!(:councils) do
      Category.create!(title: 'Scottish councils', description: '',
                       category_tag: 'scottish_council', parent_ids: [types.id])
    end
    let(:kirkhaven) do
      FactoryBot.create(:public_body,
                        name: 'Kirkhaven Council',
                        tag_string: 'local_council scottish_council scotland ' \
                                    'sic:kirkhaven')
    end
    let(:police) do
      FactoryBot.create(:public_body,
                        name: 'Caledon Police',
                        tag_string: 'police scotland')
    end

    it 'adds up its members’ figures at the top, compared with nothing else' do
      feed('sic_statistics').update!(spotlights: %w[on_time requests released])
      [glenmoor, kirkhaven].each { |body| statistics(body, %w[2025-26]) }
      police
      get '/groups/scotland'
      expect(texts('.spotlights li')).
        to eq(['75% Answered on time, 2025–26', '2,400 Requests, 2025–26',
               '70% Got some or all, 2025–26'])
      expect(page.css('.spotlights a').map { |a| a['href'] }.uniq).
        to eq(['/groups/scotland/foi_record'])
      expect(page.css('svg.strip .strip__dot').size).to eq(2)

      get '/groups/scottish_council'
      expect(texts('.spotlights li').first).
        to eq('75% Answered on time, 2025–26')
      expect(page.at_css('.spotlight__extra')).to be_nil
    end

    it 'leaves the comparison out when no member reports its timings, and copes with a stray comma' do
      counts.merge!('on_time' => 0, 'late' => 0, 'no_reply' => 0)
      [glenmoor, kirkhaven].each { |body| statistics(body, %w[2025-26]) }
      get '/groups/scotland'
      expect(response).to have_http_status(:ok)
      expect(page.at_css('#group-compare')).to be_nil
      get '/groups/scotland/foi_record'
      expect(response).to have_http_status(:ok)
      expect(page.at_css('svg.strip')).to be_nil
      expect(Topics::Holds.brief(['Bins,, roads', ''])).to eq('Bins, roads')
    end

    it 'shows each section only for the members it is for, as their own pages do' do
      feed('sic_decisions').update!(only_tags: 'local_council')
      feed('sic_statistics').update!(only_tags: 'local_council')
      decisions(glenmoor, 'sic_decisions',
                [['020/2026', Date.new(2026, 9, 1), 'For applicant',
                  'Council decision']])
      decisions(police, 'sic_decisions',
                [['021/2026', Date.new(2026, 9, 2), 'For applicant',
                  'Police decision']])
      [glenmoor, kirkhaven, police].
        each { |body| statistics(body, %w[2025-26]) }
      get '/groups/scotland'
      expect(texts('.foi-decisions__what')).
        to eq(['Council decision (another site)'])
      expect(texts('.spotlights li')).
        to eq(['75% Answered on time, 2025–26', '2,400 Requests, 2025–26'])
      get '/groups/scotland/foi_record'
      expect(texts('.foi-table tbody th')).
        to contain_exactly('Glenmoor Council', 'Kirkhaven Council')
      expect(response.body).not_to include('Police decision')
    end

    it 'leaves the figures out until at least half of its members report them' do
      statistics(glenmoor, %w[2025-26])
      kirkhaven
      police
      get '/groups/scotland'
      expect(page.at_css('.spotlights, #group-compare')).to be_nil
      expect(texts('.body-tabs a')).to eq(%w[Overview Authorities])
    end

    it 'says who does what, by name and by kind (in an admin’s words), and points to its nation’s topics' do
      glenmoor
      police
      note('<div><h1>Asking in Scotland</h1><p>Twenty working days.</p></div>',
           style: 'blue', tag: 'scotland')
      get '/groups/scotland'
      rows = page.css('.who-does li').
        to_h { |li| [li.at_css('.who-does__who').text.squish, li] }
      expect(rows['Scottish councils'].at_css('a')['href']).
        to eq('/groups/scottish_council')
      expect(rows['Caledon Police'].at_css('a')['href']).
        to eq("/body/#{police.url_name}")
      expect(rows['Caledon Police'].at_css('.who-does__what').text).
        to start_with('Crime, stop and search')
      councils.update!(
        title: 'Councils',
        description: 'Bins, roads, schools, housing and council tax'
      )
      get '/groups/scotland'
      council = page.css('.who-does li').find do |li|
        li.at_css('.who-does__who').text.squish == 'Councils'
      end
      expect(council.at_css('.who-does__what').text).
        to eq('Bins, roads, schools, housing and council tax')
      AuthorityGroups::WhoLine.save_for(police,
                                        'Crime and policing across Scotland')
      get '/groups/scotland'
      force = page.css('.who-does li').find do |li|
        li.at_css('.who-does__who').text.squish == 'Caledon Police'
      end
      expect(force.at_css('.who-does__what').text).
        to eq('Crime and policing across Scotland')
      expect(page.at_css('#group-topics').text).to eq('Topics in Scotland')
      expect(page.css('.nation-topics a').map { |a| a['href'] }).
        to all(end_with('nation=scotland'))
      expect(page.css('section[aria-labelledby="group-figures"] li')).
        not_to be_empty
      expect(page.at_css('.guide-card h2').text).to eq('Asking in Scotland')
    end

    it 'lists decisions across its members, naming each authority, and the reference for a title with no word' do
      decisions(glenmoor, 'sic_decisions',
                [['010/2026', Date.new(2026, 9, 18), 'For authority',
                  'Notes of negotiated position'],
                 ['011/2026', Date.new(2026, 9, 1), 'For applicant', '1']])
      decisions(kirkhaven, 'sic_decisions', (1..4).map do |n|
        [format('%03d/2025', n), Date.new(2025, 1, n), 'For applicant',
         "Kirkhaven decision #{n}"]
      end)
      get '/groups/scotland'
      expect(texts('.foi-decisions li .foi-decisions__ref').first(2)).
        to eq(['Glenmoor Council · 010/2026', 'Glenmoor Council · 011/2026'])
      expect(texts('.foi-decisions li .foi-decisions__what')[1]).
        to eq('011/2026 (another site)')
      expect(page.at_css('section[aria-labelledby="body-decisions"] ' \
                         '.body-more a').
               then { |link| [link.text, link['href']] }).
        to eq(['View all decisions', '/groups/scotland/foi_record'])

      get '/groups/scotland/foi_record'
      expect(page.at_css('.body-tabs a[aria-current="page"]').text).
        to eq('FOI record')
      expect(page.css('.foi-decisions li').size).to eq(6)
    end

    it 'shows every member’s figures on its FOI record tab, and every member by kind with the map on Authorities' do
      statistics(glenmoor, %w[2025-26])
      counts.merge!('on_time' => 1100, 'late' => 90, 'no_reply' => 10)
      statistics(kirkhaven, %w[2025-26])
      police
      get '/groups/scotland/foi_record'
      expect(texts('.foi-table tbody th')).
        to eq(['Kirkhaven Council', 'Glenmoor Council'])
      expect(page.css('.foi-table tbody tr').first.css('th, td').
               map { |cell| cell.text.squish }).
        to eq(['Kirkhaven Council', '1,200', '92%', '70%'])

      get '/groups/scotland/authorities'
      expect(texts('.members__kind h2')).to eq(['Scottish councils', 'Others'])
      expect(texts('.members__list li').first).to eq('Glenmoor Council')
      expect(page.css('svg.group-map a').map { |a| a.at_css('title').text }).
        to eq(['Glenmoor Council'])
    end

    it 'shows no counts: not on its tabs, nor on its links' do
      police
      6.times do |n|
        release(glenmoor, "Release #{n}", Date.new(2026, 10, n + 1))
      end
      get '/groups/scotland'
      expect(texts('.body-tabs a')).to eq(%w[Overview Authorities Documents])
      expect(texts('.body-more a')).to eq(['View all releases'])
      expect(page.at_css('.page-band__figures')).to be_nil
    end
  end

  it 'clears decision titles with no word in them, by the same Unicode rule as imports' do
    require Rails.root.
      join('db/migrate/20261026000100_clear_wordless_decision_titles').to_s
    feed = feed('ico_decisions')
    items = { 'one' => '1', 'initials' => 'H.M', 'words' => 'Mbale Trees',
              'kanji' => '税務署の記録' }.to_h do |key, title|
      [key, AuthorityFeeds::Item.create!(authority_feed_id: feed.id,
                                         occurred_on: Date.new(2026, 1, 1),
                                         reference: key, title: title,
                                         dedupe_key: "ico:#{key}")]
    end
    ActiveRecord::Migration.suppress_messages do
      ClearWordlessDecisionTitles.new.up
    end
    expect(items.transform_values { |item| item.reload.title }).
      to eq('one' => nil, 'initials' => nil, 'words' => 'Mbale Trees',
            'kanji' => '税務署の記録')
  end

  describe 'uploads' do
    before { sign_in(admin) }

    it 'refuses a file over 10 MB, and a decisions file of more than 20,000 rows, as the releases import does' do
      header = "authority,date,reference,title,outcome\n"
      expect(upload(feed('ico_decisions'),
                    header + ('x' * (10.megabytes + 1 - header.bytesize)))).
        to be_nil
      expect(response).to have_http_status(422)
      expect(response.body).to include('The file is over 10 MB. Split it.')
      expect(AuthorityFeeds::Import.count).to eq(0)

      rows = Array.new(20_001) do |index|
        "Westshire County Council,2024-06-18,IC-#{index},Roads,Upheld"
      end
      import = upload(feed('ico_decisions'), "#{header}#{rows.join("\n")}\n")
      expect(import.result.problems.map(&:message)).
        to eq(['More than 20000 rows. Split the file.'])
      expect(import.result.rows).to eq([])
    end

    it 'previews without saving, applies once, and matches the same rows next time' do
      westshire
      csv = <<~CSV
        authority,date,reference,title,outcome
        Westshire County Council,2024-06-18,IC-1,Boundary line data,Not upheld
        Westshire County Council,2024-06-18,IC-1,Boundary line data,Not upheld
        Westshire County Council,someday,IC-2,Roads,Upheld
        Westshire County Council,2023-01-31,IC-3,SEND board papers,Upheld
      CSV
      import = upload(feed('ico_decisions'), csv)
      expect(texts('h1').first).to start_with('ICO decisions:')
      expect(page.text.squish).
        to include('2 new · 0 already here · 2 problems')
      expect(AuthorityFeeds::Item.count).to eq(0)

      post apply_admin_authority_feed_import_path(feed('ico_decisions'), import)
      expect(AuthorityFeeds::Item.count).to eq(2)
      expect(AuthorityFeeds::Summary.find_by(public_body: westshire).
               items_count).to eq(2)
      post apply_admin_authority_feed_import_path(feed('ico_decisions'), import)
      expect(flash[:error]).to eq('This import has already been applied.')

      again = upload(feed('ico_decisions'), csv)
      expect(page.text.squish).to include('0 new · 2 already here')
      post apply_admin_authority_feed_import_path(feed('ico_decisions'), again)
      expect(AuthorityFeeds::Item.count).to eq(2)
    end

    it 'takes the statistics JSON, matching authorities by their sic: tag' do
      data = {
        'source' => FoiStatistics::SOURCE, 'latest' => '2025-26',
        'scotland' => { '2025-26' => counts },
        'authorities' => {
          'glenmoor' => { 'name' => 'Glenmoor Council',
                          'note' => 'Figures include the licensing board',
                          'years' => { '2025-26' => counts } },
          'elsewhere' => { 'name' => 'Elsewhere Board',
                           'years' => { '2025-26' => counts } }
        }
      }
      glenmoor
      upload(feed('sic_statistics'), data.to_json,
             filename: 'scotland.json', type: 'application/json')
      expect(texts('h2')).to include('Names to match')
      expect(texts('ul li')).to include('Elsewhere Board')
      post apply_admin_authority_feed_import_path(feed('sic_statistics'),
                                                  AuthorityFeeds::Import.last)
      record = FoiStatistics.for_body(glenmoor)
      expect([record.year, record.requests, record.on_time, record.released,
              record.note]).
        to eq(['2025-26', 1200, 75, 70, 'Figures include the licensing board'])
    end

    it 'keeps decisions under names it can’t match, until an admin matches the name once' do
      westshire
      upload(feed('ico_decisions'), <<~CSV)
        authority,date,reference,title,outcome,url
        Westshire CC,2024-06-18,IC-292779-K9Y5,Boundary line data,Complaint not upheld,https://ico.org.uk/a
        Westshire County Council,2023-01-31,IC-174084-G6P5,SEND board papers,Upheld,https://ico.org.uk/b
      CSV
      expect(page.text.squish).to include('1 name to match')
      post apply_admin_authority_feed_import_path(feed('ico_decisions'),
                                                  AuthorityFeeds::Import.last)
      expect(AuthorityFeeds::Item.where(public_body: westshire).
               pluck(:outcome)).to eq(['Upheld'])

      get admin_authority_feed_names_path(feed('ico_decisions'))
      expect(texts('tbody td:first-child')).to eq(['Westshire CC'])
      post admin_authority_feed_names_path(feed('ico_decisions')),
           params: { name: 'Westshire CC', url_name: westshire.url_name }
      expect(AuthorityFeeds::Item.where(public_body: westshire).
               order(:occurred_on).pluck(:outcome)).
        to eq(['Upheld', 'Not upheld'])
      expect(AuthorityFeeds::Summary.find_by(public_body: westshire).
               items_count).to eq(2)

      get "/body/#{westshire.url_name}"
      expect(page.at_css('#body-decisions').text).to eq('ICO decisions')
      expect(page.css('.body-hub .group-page__source').map(&:text).join).
        to include('Newest from June 2024.')
    end
  end

  describe 'the daily check' do
    it 'decides freshness by state, so the words admins read can change' do
      stub_const('AuthorityFeeds::Feed::STATUSES',
                 { late: 'Behind', not_started: 'Waiting',
                   up_to_date: 'Current' })
      checked = feed('ico_decisions')
      checked.update_columns(checked_at: Time.current, check_error: nil)
      expect(checked).to have_attributes(status: 'Current', up_to_date?: true,
                                         late?: false)
      checked.update_columns(check_error: 'timeout')
      expect(checked).to have_attributes(status: 'Behind', late?: true,
                                         up_to_date?: false)
    end

    let(:http) { instance_double(AuthorityFeeds::Fetch::Http) }

    def ico_result(id, authority, date, statuses, path)
      { 'filterItemMetaData' => "#{date}, Local government",
        'title' => authority, 'id' => id, 'url' => path,
        'description' => 'The complainant requested information from ' \
                         'Westshire County Council (the “Council”) ' \
                         'regarding road gritting. The Commissioner’s ' \
                         'decision is…',
        'filterItemDecisions' => statuses.map do |status|
          { 'status' => status, 'section' => 'FOI 12(1)' }
        end }
    end

    it 'saves new ICO notices with the overall outcome, a short title and the authority' do
      westshire
      page1 = {
        'results' => [
          ico_result(1, 'Westshire County Council', '17 October 2026',
                     ['Upheld', 'Not upheld'],
                     '/action-weve-taken/decision-notices/2026/10/' \
                     'ic-465234-m1m2/'),
          ico_result(2, 'Westshire County Council', '16 October 2026',
                     ['Not upheld'],
                     '/action-weve-taken/decision-notices/2026/10/' \
                     'ic-465235-a1b2/')
        ],
        'pagination' => { 'hasMore' => true }
      }
      page2 = {
        'results' => [
          ico_result(3, 'Nobody We Know', '15 October 2026', ['Upheld'],
                     '/action-weve-taken/decision-notices/2026/10/' \
                     'ic-465236-c3d4/')
        ],
        'pagination' => { 'hasMore' => false }
      }
      allow(http).to receive(:post_json).
        and_return(page1.to_json, page2.to_json)
      result = AuthorityFeeds::Fetch.run_one(feed('ico_decisions'), http)

      expect(result).to eq(added: 3, updated: 0)
      expect(http).to have_received(:post_json).
        with(AuthorityFeeds::Fetch::Ico::URL,
             hash_including(order: 'newest', rootPageId: 13_635)).twice
      saved = AuthorityFeeds::Item.where(public_body: westshire).
        order(:occurred_on).pluck(:reference, :outcome, :title, :occurred_on)
      expect(saved).to eq([['IC-465235-A1B2', 'Not upheld', 'Road gritting',
                            Date.new(2026, 10, 16)],
                           ['IC-465234-M1M2', 'Partly upheld', 'Road gritting',
                            Date.new(2026, 10, 17)]])
      expect(AuthorityFeeds::Item.where(public_body_id: nil).
               pluck(:authority_name)).to eq(['Nobody We Know'])
      expect(feed('ico_decisions').status).to eq('Up to date')

      allow(http).to receive(:post_json).and_return(page2.to_json)
      expect(AuthorityFeeds::Fetch.run_one(feed('ico_decisions'), http)).
        to eq(added: 0, updated: 1)
    end

    it 'reads the Commissioner’s table, stopping at a page it has seen' do
      glenmoor
      html = <<~HTML
        <table><tbody>
          <tr><td><a href="/decisions/003-2026">003/2026</a></td><td>Glenmoor Council</td><td>Whether request was repeated [...] view full decision</td><td>For applicant</td><td>13/01/2026</td><td></td><td></td><td></td></tr>
        </tbody></table>
      HTML
      AuthorityFeeds::NameAlias.create!(feed: feed('sic_decisions'),
                                        name: 'Glenmoor Council',
                                        public_body: glenmoor)
      allow(http).to receive(:get).and_return(html)
      AuthorityFeeds::Fetch.run_one(feed('sic_decisions'), http)
      expect(http).to have_received(:get).
        with(AuthorityFeeds::Fetch::Sic::URL).once
      expect(http).to have_received(:get).
        with("#{AuthorityFeeds::Fetch::Sic::URL}?page=1").once
      expect(AuthorityFeeds::Item.where(public_body: glenmoor).
               pluck(:reference, :title, :outcome)).
        to eq([['003/2026', 'Whether request was repeated', 'Upheld']])
    end

    it 'keeps a failure on the section, which then shows as late' do
      allow(http).to receive(:post_json).
        and_raise(AuthorityFeeds::Fetch::Http::Failed,
                  'ico.org.uk answered 503')
      expect(AuthorityFeeds::Fetch.run_one(feed('ico_decisions'), http)).
        to eq(error: 'ico.org.uk answered 503')
      expect(feed('ico_decisions').status).to eq('Late')

      sign_in(admin)
      get admin_authority_pages_path
      expect(page.at_css('.alert').text.squish).
        to include('ICO decisions: the last check failed ' \
                   '(ico.org.uk answered 503)')
    end

    it 'reads a page, and gives up on one too big to be decisions' do
      stub_request(:get, AuthorityFeeds::Fetch::Sic::URL).
        to_return(body: '<table></table>')
      expect(AuthorityFeeds::Fetch::Http.new.
               get(AuthorityFeeds::Fetch::Sic::URL)).to eq('<table></table>')

      stub_const('AuthorityFeeds::Fetch::Http::MAX_BYTES', 10)
      expect do
        AuthorityFeeds::Fetch::Http.new.get(AuthorityFeeds::Fetch::Sic::URL)
      end.to raise_error(AuthorityFeeds::Fetch::Http::Failed,
                         /\Awww.foi.scot sent more than/)
    end
  end

  describe 'the admin pages' do
    it 'are for admins only' do
      allow(AlaveteliConfiguration).to receive(:skip_admin_auth).
        and_return(false)
      sign_in(FactoryBot.create(:user))
      get admin_authority_pages_path
      expect(response).not_to have_http_status(:ok)
    end

    it 'edit a section: what goes to the top, how often it updates, and hiding it' do
      sign_in(admin)
      get admin_authority_pages_path
      expect(texts('table').first).
        to include('FOI record', 'Commissioner decisions', 'ICO decisions')
      patch admin_authority_feed_path(feed('sic_statistics')),
            params: { feed: { heading: 'FOI record',
                              spotlights: ['', 'released'],
                              updates: 'yearly', hidden: '0' } }
      expect(feed('sic_statistics').spotlights).to eq(['released'])
      patch admin_authority_feed_path(feed('sic_statistics')),
            params: { feed: { spotlights: ['nonsense'] } }
      expect(response).to have_http_status(422)
      patch admin_authority_feed_path(feed('ico_decisions')),
            params: { feed: { hidden: '1' } }
      expect(feed('ico_decisions').hidden?).to be(true)
    end

    it 'save a named authority’s Who does what line, refuse one too long, and clear it with a blank one' do
      skip 'Admin public body summary arrives in B15'
      police = FactoryBot.create(:public_body, name: 'Caledon Police',
                                               tag_string: 'police scotland')
      sign_in(admin)
      get admin_body_path(police)
      expect(page.at_css('#body-who input[name=line]')['placeholder']).
        to start_with('Crime, stop and search')
      post admin_body_who_line_path(police),
           params: { line: '  Crime and policing   across Scotland ' }
      expect(AuthorityGroups::WhoLine.find_by(public_body: police).line).
        to eq('Crime and policing across Scotland')
      post admin_body_who_line_path(police), params: { line: 'x' * 201 }
      expect(response).
        to redirect_to(admin_body_path(police, anchor: 'body-who'))
      expect(flash[:error]).to include('200 characters')
      expect(AuthorityGroups::WhoLine.find_by(public_body: police).line).
        to eq('Crime and policing across Scotland')
      post admin_body_who_line_path(police), params: { line: '' }
      expect(AuthorityGroups::WhoLine.where(public_body: police)).to be_empty
      get admin_body_path(ashdown)
      expect(page.at_css('#body-who')).to be_nil
    end

    it 'save the What they hold checklist as holds_not tags, leaving other tags alone' do
      skip 'Admin public body summary arrives in B15'
      sign_in(admin)
      get admin_body_path(ashdown)
      boxes = page.css('#body-holds input[type=checkbox]').
        map { |box| box['value'] }
      expect(boxes).to include('bins_street', 'food_hygiene')
      post admin_body_holds_path(ashdown),
           params: { held: boxes - ['food_hygiene'] }
      expect(ashdown.reload.tag_string.split).
        to include('holds_not:food_hygiene', 'gss:E07000200')
      post admin_body_holds_path(ashdown), params: { held: boxes }
      expect(ashdown.reload.tag_string).not_to include('holds_not')
    end
  end

  describe AuthorityFeeds::Freshness do
    it 'keeps a financial year current until the next is due, and a month for two more' do
      expect(described_class.period_end('2025-26', 'yearly')).
        to eq(Date.new(2026, 3, 31))
      expect(described_class.current?('2025-26', 'yearly',
                                      today: Date.new(2027, 6, 30))).
        to be(true)
      expect(described_class.current?('2025-26', 'yearly',
                                      today: Date.new(2027, 7, 1))).
        to be(false)
      expect(described_class.current?('2026-08', 'monthly',
                                      today: Date.new(2026, 10, 23))).
        to be(true)
      expect(described_class.current?('2026-07', 'monthly',
                                      today: Date.new(2026, 10, 23))).
        to be(false)
      expect(described_class.current?('nonsense', 'yearly')).to be(false)
    end
  end

  it 'loads all its classes' do
    expect { Rails.autoloaders.main.eager_load_namespace(AuthorityFeeds) }.
      not_to raise_error
  end

  def upload(feed, text, filename: 'rows.csv', type: 'text/csv')
    file = Tempfile.new(['upload', File.extname(filename)])
    file.binmode
    file.write(text)
    file.rewind
    post admin_authority_feed_imports_path(feed), params: {
      file: Rack::Test::UploadedFile.new(file.path, type,
                                         original_filename: filename)
    }
    follow_redirect! if response.redirect?
    AuthorityFeeds::Import.order(:id).last
  ensure
    file&.close!
  end
end
