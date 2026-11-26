require 'spec_helper'

RSpec.describe 'Topics' do
  include_context 'with production error pages'

  before do
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    allow(AlaveteliFeatures.backend).to receive(:enabled?).
      with(:alaveteli_pro).and_return(true)
  end

  let(:topics) { Topics::Topic.all }

  def page
    Nokogiri::HTML(response.body)
  end

  def row(heading_id, text)
    page.css("##{heading_id} ~ * li").find { |node| node.text.include?(text) }
  end

  def question_page(slug, words, nation: nil)
    question = Topics::Topic.find(slug).questions.find do |each|
      each.text.include?(words) && each.useful_for?(nation || 'england')
    end
    get topic_question_path(slug, question.slug, nation: nation)
  end

  def ask_link
    page.at('.topic-question__main a[data-ask]')
  end

  def sign_in_someone
    user = FactoryBot.create(:user)
    sign_in(user)
  end

  def with_whatdotheyknow
    allow(AlaveteliConfiguration).to receive(:other_foi_site_name).
      and_return('WhatDoTheyKnow')
    allow(AlaveteliConfiguration).to receive(:other_foi_site_url).
      and_return('https://www.whatdotheyknow.com/select_authority')
  end

  def without_other_site
    allow(AlaveteliConfiguration).to receive(:other_foi_site_name).
      and_return('')
    allow(AlaveteliConfiguration).to receive(:other_foi_site_url).and_return('')
  end

  def with_signups_closed
    allow(AlaveteliConfiguration).to receive(:read_only_features).
      and_return(['signups'])
  end

  describe 'the content' do
    it 'loads every topic, in order' do
      expect(topics.map(&:slug)).
        to eq(%w[streets policing health spending tax homes rivers care])
    end

    it 'shows a change on the next page, as another app process would' do
      get '/topics'
      expect(page.css('.triage-reply__topic').map(&:text)).
        not_to include('Bins and potholes')
      TopicPage.find_by!(slug: 'streets').update!(summary: 'Bins and potholes')
      get '/topics'
      expect(page.css('.triage-reply__topic').map(&:text)).
        to include('Bins and potholes')
    end

    it 'shows a change made earlier in the same request' do
      expect(Topics::Topic.find('streets').summary).not_to eq('Potholes')
      TopicPage.find_by!(slug: 'streets').update!(summary: 'Potholes')
      expect(Topics::Topic.find('streets').summary).to eq('Potholes')
    end

    it 'leaves topics out of every page while there are none' do
      [TopicHolder, TopicQuestion, TopicSource, TopicRoute, TopicPage,
       TopicDataset, TopicChange].each(&:delete_all)
      body = public_bodies(:geraldine_public_body)
      ['/', '/topics', '/documents',
       show_public_body_path(url_name: body.url_name)].each do |path|
        get path
        expect(response).to have_http_status(:ok), path
      end
      get '/topics/streets'
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses a misspelt key' do
      expect do
        Topics::Topic.new('x', 'title' => 'X', 'summary' => 'X', 'order' => 1,
                               'holders' => [{ 'whoo' => 'X' }])
      end.to raise_error(ArgumentError)
    end
  end

  describe 'the torch' do
    let(:helper) { Class.new { include Topics::TopicsHelper }.new }

    it 'meets the disc at tangents, so the beam edge runs along the circle' do
      helper.torch_tangent(5.0, 5.0, 2.0, 20.0, 1.0).each do |x, y|
        expect(Math.hypot(x - 5, y - 5)).to be_within(1e-9).of(2.0)
        expect(((x - 5) * (20 - x)) + ((y - 5) * (1 - y))).
          to be_within(1e-9).of(0)
      end
    end
  end

  describe 'the index' do
    it 'lists every topic plainly, with no torch' do
      get '/topics'
      expect(response).to have_http_status(:ok)
      expect(page.css('.triage-replies--topics a').map { |a| a['href'] }).
        to eq(topics.map { |t| "/topics/#{t.slug}" })
      expect(page.css('.triage-replies--topics .triage-reply__topic').
               map(&:text)).to eq(topics.map(&:summary))
      expect(page.at('.torch')).to be_nil
      expect(page.at('body')['class']).not_to include('has-page-search')
    end
  end

  describe 'the home page' do
    it 'shows the first six topics, then all of them on one row, each row with its beam' do
      get '/'
      expect(response).to have_http_status(:ok)
      shown = topics.sort_by(&:order).first(Topics::Topic::HOME)
      links = page.css('.torch__row a').map { |a| a['href'] }
      expect(links).to eq(shown.map { |t| "/topics/#{t.slug}" } + ['/topics'])
      expect(page.at('.torch__row--all').text.strip).to eq('All topics')
      rows = page.css('.torch__find, .torch__row').size
      expect(rows).to eq(Topics::Topic::HOME + 2)
      expect(page.at('.torch')['style']).
        to start_with("--rows: #{rows}; --beam-0: polygon(")
      expect(page.at('.torch')['style'].scan(/--beam-\d+/).size).to eq(rows)
      expect(page.at('.torch__search')['action']).to eq('/documents')
    end

    it 'shows no recent releases on an empty site' do
      get '/'
      expect(page.at('.papers')).to be_nil
    end

    it "lists each topic's first question, linked to its questions" do
      get '/'
      first = topics.first
      question = first.questions.find { |each| each.useful_for?('england') }
      link = page.css('a.asked__question').first
      expect([link.text, link['href']]).
        to eq([question.text, "/topics/#{first.slug}/#{question.slug}"])
      expect(page.at_css('.asked').text).not_to include('Published elsewhere')
    end
  end

  describe 'a topic page' do
    it 'renders every topic' do
      topics.each do |topic|
        get "/topics/#{topic.slug}"
        expect(response).to have_http_status(:ok), topic.slug
        expect(page.at('#content h1').text).to eq(topic.title)
      end
    end

    it 'is a 404 for an unknown topic' do
      get '/topics/nothing-here'
      expect(response).to have_http_status(:not_found)
    end

    it 'links an authority on this site, and asks it directly' do
      body = FactoryBot.create(:public_body,
                               name: 'Revenue and Benefits Agency')
      sign_in_someone
      get '/topics/tax/who-holds-it'
      link = URI(row('topic-who', 'Family Allowance').at('a')['href'])
      expect(link.path).to eq("/body/#{body.url_name}")
      expect(Rack::Utils.parse_nested_query(link.query).
               dig('request_choice', 'journey')).
        to include('topic' => 'tax', 'nation' => 'england')
      question_page('tax', 'tax fraud')
      expect(Rack::Utils.parse_nested_query(URI(ask_link['href']).query)).
        to include('public_body' => body.url_name)
    end

    it 'searches WhatDoTheyKnow for an authority that is not on this site, and says so' do
      with_whatdotheyknow
      get '/topics/tax/who-holds-it'
      holder = row('topic-who', 'Family Allowance')
      link = holder.at('a')
      expect(link['href']).to eq('https://www.whatdotheyknow.com/select_authority?query=Revenue+and+Benefits+Agency')
      expect(link['class']).to eq('topic-out')
      expect(holder.at('.topic-holders__who').text).
        to include(", on\u00a0WhatDoTheyKnow")
      sign_in_someone
      question_page('tax', 'tax fraud')
      ask = ask_link
      expect(ask['href']).to eq('https://www.whatdotheyknow.com/select_authority?query=Revenue+and+Benefits+Agency')
      expect(ask.text).to start_with('Ask on WhatDoTheyKnow')
      expect(ask['class']).to include('topic-out')
    end

    it 'falls back to the holder’s WhatDoTheyKnow search when a question’s Ask tag has no authorities here' do
      with_whatdotheyknow
      sign_in_someone
      question_page('health', 'agency staff', nation: 'wales')
      ask = ask_link
      expect(ask['href']).to eq('https://www.whatdotheyknow.com/select_authority?query=health+board')
      expect(ask.text).to include('(another site)')
    end

    it 'gives a visitor a note in place of Ask, pointing to the authority on WhatDoTheyKnow' do
      with_whatdotheyknow
      with_signups_closed
      FactoryBot.create(:public_body, tag_string: 'police')
      question_page('policing', 'facial recognition')
      note = page.at('.topic-question__main details.ask-elsewhere')
      expect(note.at('summary').text).to start_with('Make request')
      expect(note.at('.ask-elsewhere__note').text.squish).
        to eq('Accounts here are invite-only. You can ask on WhatDoTheyKnow ' \
              '(another site) instead. Your request and any replies there ' \
              'will be public.')
      expect(note.at('a')['href']).to eq('https://www.whatdotheyknow.com/select_authority?query=police')
      expect(page.css('a.triage-btn[data-ask]')).to be_empty
      expect(response.body).not_to include('/profile/sign_in?r=/new')
      # Escape closes it.
      expect(note['data-controller']).to eq('details-escape')

      body = FactoryBot.create(:public_body, name: 'Northmoor Fire Service')
      get "/body/#{body.url_name}"
      band = page.at('.page-band details.ask-elsewhere')
      expect(band.at('summary').text).
        to eq('Make request: Northmoor Fire Service')
      expect(band.at('a')['href']).to eq('https://www.whatdotheyknow.com/select_authority?query=Northmoor+Fire+Service')

      sign_in_someone
      get "/body/#{body.url_name}"
      expect(page.at('.page-band a.page-band__button')['href']).
        to eq(new_alaveteli_pro_info_request_path(public_body: body.url_name))
      expect(page.at('details.ask-elsewhere')).to be_nil
    end

    it "falls back to a tag's WhatDoTheyKnow search when no authority has the tag" do
      with_whatdotheyknow
      get '/topics/policing/who-holds-it'
      link = row('topic-who', 'stop and search, complaints').at('a')
      expect(link['href']).to eq('https://www.whatdotheyknow.com/select_authority?query=police')
    end

    it 'leaves an authority that is not on this site as plain text when there is no other site' do
      without_other_site
      get '/topics/tax/who-holds-it'
      holder = row('topic-who', 'Family Allowance')
      expect(holder.at('.topic-holders__who a')).to be_nil
      expect(holder.at('.topic-holders__who').text).
        to eq('Revenue and Benefits Agency')
      sign_in_someone
      question_page('tax', 'tax fraud')
      expect(ask_link).to be_nil
      get '/topics/rivers/who-holds-it'
      expect(row('topic-elsewhere', 'from water companies').at('a')).to be_nil
      expect(page.text).not_to include('are published.')
    end

    it 'gives a visitor Make request while sign-ups are open' do
      FactoryBot.create(:public_body, tag_string: 'police')
      body = FactoryBot.create(:public_body, name: 'Northmoor Fire Service')
      question_page('policing', 'facial recognition')
      expect(ask_link.text).to start_with('Make request')
      expect(page.css('details.ask-elsewhere')).to be_empty
      expect(page.text).not_to include('Accounts here are invite-only')
      get "/body/#{body.url_name}"
      expect(page.at('.page-band a.page-band__button')['href']).
        to eq("/new/#{body.url_name}")
    end

    it 'says accounts are by invitation, with nowhere else to ask, when sign-ups are closed and there is no other site' do
      without_other_site
      with_signups_closed
      FactoryBot.create(:public_body, tag_string: 'police')
      question_page('policing', 'facial recognition')
      note = page.at('.topic-question__main details.ask-elsewhere')
      expect(note.at('.ask-elsewhere__note').text.squish).
        to eq('Accounts here are invite-only.')
      expect(note.at('a')).to be_nil
    end

    it 'sends an authority type to the list of authorities with its tag when it has no group' do
      FactoryBot.create(:public_body, tag_string: 'police')
      get '/topics/policing/who-holds-it'
      expect(page.at('.topic-groups a')['href']).to eq('/body/list/police')
    end

    it 'marks outside links and says WhatDoTheyKnow requests are published' do
      with_whatdotheyknow
      get '/topics/rivers/who-holds-it'
      wdtk = row('topic-elsewhere', 'from water companies').at('a')
      expect(wdtk['href']).to eq('https://www.whatdotheyknow.com/select_authority?query=water+company')
      expect(wdtk['class']).to eq('topic-out')
      expect(wdtk.text).to include('(another site)')
      expect(page.text).to include('Requests on WhatDoTheyKnow are published.')
    end

    it 'shows a source once: on its question’s page, or in Already published, and a holder never also as another route' do
      question_page('policing', 'burglaries')
      expect(page.css('a.topic-out').map { _1['href'] }).
        to include(Topics::Dataset.find('northmoor-recorded-crime').url)
      linked = Topics::Guide.new(Topics::Topic.find('policing'), 'england').
               entries.filter_map(&:url)
      get '/topics/policing/who-holds-it'
      expect(page.css('.topic-published a').map { _1['href'] } & linked).
        to be_empty
      expect(page.at('#topic-published').text).to eq('Already published')
      holders = page.css('.topic-holders a').map { _1['href'] }
      expect(page.css('.topic-elsewhere a').map { _1['href'] } & holders).
        to be_empty
    end

    it 'leaves out "Published here" when nothing has been published for a topic' do
      get '/topics/health'
      expect(page.at('#topic-papers')).to be_nil
    end

    it 'shows one nation at a time, England unless another is picked' do
      with_whatdotheyknow
      get '/topics/streets/who-holds-it'
      expect(page.at('.nation-tabs [aria-current]').text).to eq('England')
      expect(page.at('#topic-who').text).to eq('Who holds it')

      get '/topics/streets/who-holds-it', params: { nation: 'northern_ireland' }
      expect(page.at('.nation-tabs [aria-current]').text).
        to eq('Northern Ireland')
      expect(page.css('.topic-holders__who').map(&:text)).
        to include('Roads Department, not the council (another site), ' \
                   "on\u00a0WhatDoTheyKnow")
      expect(page.css('.topic-holders__who').map(&:text)).
        not_to include('Your county or unitary council')

      get '/topics/streets/who-holds-it', params: { nation: 'atlantis' }
      expect(page.at('.nation-tabs [aria-current]').text).to eq('England')
    end

    it 'links an authority type to its group, only when the group exists' do
      get '/topics/policing/who-holds-it'
      expect(page.at('.topic-groups')).to be_nil

      heading = Category.create!(title: 'Type', description: '',
                                 parent_ids: [PublicBody.category_root.id])
      Category.create!(title: 'Police forces', description: '',
                       category_tag: 'police', parent_ids: [heading.id])
      get '/topics/policing/who-holds-it'
      expect(page.at('.topic-groups a').then { |a| [a.text, a['href']] }).
        to eq(['Police forces', '/groups/police'])
    end

    it 'sends council holders to the places, not to each kind of council' do
      get '/topics/streets/who-holds-it'
      expect(page.at('.topic-page__find')).to be_nil

      heading = Category.create!(title: 'Type', description: '',
                                 parent_ids: [PublicBody.category_root.id])
      Category.create!(title: 'Unitary councils', description: '',
                       category_tag: 'unitary_authority',
                       parent_ids: [heading.id])
      get '/topics/streets/who-holds-it'
      expect(page.at('#topic-who .topic-groups')).to be_nil
      expect(page.at('.topic-page__find a')['href']).
        to eq('/groups#groups-place')
    end

    it 'shows only the nation’s own group on a holder shared by several nations' do
      helper = Class.new do
        include Topics::TopicsHelper
        include RequestJourney::NavigationHelper
        def current_user
          nil
        end
      end.new
      allow(helper).to receive(:topic_tag_path) { |tag| "/groups/#{tag}" }
      groups = [{ 'label' => 'Scottish councils', 'tag' => 'scottish_council' },
                { 'label' => 'Welsh councils', 'tag' => 'welsh_council' }]
      expect(helper.topic_groups(groups, 'scotland').map(&:first)).
        to eq(['Scottish councils'])
      expect(helper.topic_groups(groups, 'wales').map(&:first)).
        to eq(['Welsh councils'])
    end

    it 'leaves out a heading with nothing under it for the nation, and puts the questions before Published here' do
      get '/topics/streets/who-holds-it', params: { nation: 'wales' }
      expect(page.at('#topic-published')).to be_nil
      get '/topics/streets/who-holds-it'
      expect(page.at('#topic-published')).to be_present
      get '/topics/streets'
      expect(page.css('.topic-page h2').map { _1['id'] }.first(2)).
        to eq(%w[topic-look topic-ask])
    end

    it 'gives what they hold and who holds it as main text, with no label above' do
      get '/topics/streets/who-holds-it'
      holder = row('topic-who', 'motorway service areas')
      expect(holder.at('.topic-holders__what').text).
        to eq('Trunk roads and motorway service areas')
      expect(holder.css('.topic-nation')).to be_empty
    end

    describe 'documents named in the topic’s file' do
      include PublicationFeedHelpers
      include_context 'with document OCR off'

      let(:helper) { Class.new { include Topics::TopicsHelper }.new }

      def topic
        Topics::Topic.find('streets')
      end

      def name_documents(public_ids)
        TopicPage.find_by!(slug: 'streets').update!(documents: public_ids)
      end

      def public_id(id)
        Disclosures::Document.find(id).public_id
      end

      # No group is tagged with a nation here, so each authority's own tags
      # decide its nation; a sic: tag counts as Scotland.
      it 'keeps a nation’s documents to its own authorities, in the file’s order' do
        base = expand_catalogue(make_feed_document, 4)
        tags = { scotland: 'scotland', sic: 'local_council sic:glenmoor',
                 wales: 'wales', england: 'local_council' }
        bodies = tags.transform_values do |tag_string|
          FactoryBot.create(:public_body, tag_string: tag_string)
        end
        Disclosures::Document.where('id > ?', base).order(:id).
          zip(bodies.values).each do |doc, body|
            doc.update_columns(public_body_id: body.id)
          end
        Disclosures::Page.where('document_id > ?', base).
          update_all(text: 'Parking fines by street')
        Disclosures::TopicMatch.rebuild
        ids = tags.keys.each_with_index.
          to_h { |key, index| [key, base + index + 1] }
        name_documents(ids.values.reverse.map { |id| public_id(id) })
        found = ->(nation) do
          helper.topic_documents(topic, 5, nation).map(&:id)
        end

        expect(found.call('scotland')).to eq(ids.values_at(:sic, :scotland))
        expect(found.call('wales')).to eq([ids[:wales]])
        expect(found.call('northern_ireland')).to eq([])
        expect(found.call('england')).to eq([ids[:england]])

        get '/topics/streets', params: { nation: 'scotland' }
        expect(page.css('.paper__meta').map(&:text)).
          to match_array(bodies.values_at(:scotland, :sic).map(&:name))
        link = page.at_css('section[aria-labelledby="topic-papers"] p a')
        expect(link.text).to eq('View all documents')
        get link['href']
        expect(page.at('#documents-count').text.squish).to eq('2 documents')
        expect(page.css('.documents__active strong').map(&:text)).
          to match_array(['Scotland', 'Streets and bins'])
      end

      it 'drops a document that stops being public, at once' do
        document = make_feed_document
        name_documents([document.public_id])
        expect(helper.topic_documents(topic, 3)).to eq([document])

        document.update_columns(state: 'withdrawn')
        expect(helper.topic_documents(topic, 3)).to eq([])

        get '/topics/streets'
        expect(page.at_css('section[aria-labelledby="topic-papers"]')).to be_nil
      end

      it 'stops at the limit, and shows nothing for a topic that names none' do
        ids = expand_catalogue(make_feed_document, 4).then do |base|
          (1..4).map { |n| public_id(base + n) }
        end
        name_documents(ids)
        expect(helper.topic_documents(topic, 3).map(&:public_id)).
          to eq(ids.first(3))

        name_documents([])
        expect(helper.topic_documents(topic, 3)).to eq([])
      end

      it 'refuses anything but public ids in the file' do
        data = { 'title' => 'T', 'summary' => 'S', 'order' => 1 }
        expect(
          Topics::Topic.new(
            't',
            data.merge('documents' => ['abcdefghij12'])
          ).documents
        ).to eq(['abcdefghij12'])
        expect(
          Topics::Topic.new('t', data.merge('documents' => nil)).documents
        ).to eq([])
        ['Not an id', 123_456_789_012].each do |id|
          expect { Topics::Topic.new('t', data.merge('documents' => [id])) }.
            to raise_error(ArgumentError, /public ids/)
        end
      end
    end

    it 'shows what is usually refused' do
      get '/topics/spending/who-holds-it'
      expect(page.at('.topic-refused').text).
        to include('still being negotiated')
    end
  end

  it 'keeps a query already in the other site’s address' do
    with_whatdotheyknow
    allow(AlaveteliConfiguration).to receive(:other_foi_site_url).and_return('https://example.org/select_authority?lang=cy')
    expect(Topics::OtherSite.url('Northmoor & District')).
      to eq('https://example.org/select_authority?lang=cy&query=Northmoor+%26+District')
  end
end
