require 'spec_helper'

RSpec.describe 'Topic pages' do
  include_context 'with production error pages'

  before do
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    allow(AlaveteliFeatures.backend).to receive(:enabled?).
      with(:alaveteli_pro).and_return(true)
  end

  let(:topic) { Topics::Topic.all.first }
  let(:guide) { Topics::Guide.new(topic, 'england') }

  def page
    Nokogiri::HTML(response.body)
  end

  def hrefs(selector)
    page.css(selector).map { |link| link['href'] }
  end

  it 'renders every topic, question and Who holds it, in every nation' do
    Topics::Topic.all.each do |each|
      Topics::Topic::NATIONS.each_key do |nation|
        get topic_path(each.slug, nation: nation)
        expect(response).to have_http_status(:ok), [each.slug, nation].inspect
        get topic_holders_path(each.slug, nation: nation)
        expect(response).to have_http_status(:ok), [each.slug, nation].inspect
        Topics::Guide.new(each, nation).entries.each do |entry|
          get topic_question_path(each.slug, entry.slug, nation: nation)
          expect(response).
            to have_http_status(:ok), [each.slug, nation, entry.slug].inspect
          expect(page.at('#content h1').text).to eq(entry.question.text)
        end
      end
    end
  end

  it 'renders them signed in' do
    sign_in FactoryBot.create(:user)
    get topic_path(topic.slug)
    expect(response).to have_http_status(:ok)
    get topic_question_path(topic.slug, guide.entries.first.slug)
    expect(response).to have_http_status(:ok)
    get topic_holders_path(topic.slug)
    expect(response).to have_http_status(:ok)
  end

  it 'sorts the questions into Look it up and Ask for it, each to its own page' do
    get topic_path(topic.slug)
    expect(page.css('.topic-sorted h2').map(&:text)).
      to eq(['Look it up', 'Ask for it'])
    expect(hrefs('.topic-sorted__look a')).
      to eq(guide.look_up.map { "/topics/#{topic.slug}/#{_1.slug}" })
    expect(hrefs('.topic-sorted__ask a')).
      to eq(guide.ask_for.map { "/topics/#{topic.slug}/#{_1.slug}" } +
            ["/topics/#{topic.slug}/who-holds-it"])
    expect(page.at('.topic-sorted__ask a:last-child').text).
      to eq('Something not listed')
  end

  it 'leaves outside links to the question pages' do
    get topic_path(topic.slug)
    expect(page.css('.topic-sorted a.topic-out')).to be_empty
    entry = guide.look_up.first
    get topic_question_path(topic.slug, entry.slug)
    expect(hrefs('a.topic-out')).to include(entry.url)
  end

  it 'keeps a question’s address when its wording changes' do
    question = Topics::Topic::Question.new(text: 'How many?', slug: 'counts')
    expect(question.slug).to eq('counts')
    expect(Topics::Topic::Question.new(text: 'How many bins?').slug).
      to eq('how-many-bins')
  end

  it 'refuses a slug twice in a topic, or one an address needs' do
    data = { 'title' => 'T', 'summary' => 'S', 'order' => 1 }
    twice = [{ 'text' => 'A?', 'slug' => 'a' },
             { 'text' => 'B?', 'slug' => 'a' }]
    expect { Topics::Topic.new('t', data.merge('questions' => twice)) }.
      to raise_error(ArgumentError, /two questions use the slug a/)
    by_nation = [{ 'text' => 'A?', 'slug' => 'a', 'nations' => ['wales'] },
                 { 'text' => 'B?', 'slug' => 'a', 'nations' => ['scotland'] }]
    expect(Topics::Topic.new('t', data.merge('questions' => by_nation)).
             questions.map(&:slug)).to eq(%w[a a])
    reserved = [{ 'text' => 'A?', 'slug' => 'who-holds-it' }]
    expect { Topics::Topic.new('t', data.merge('questions' => reserved)) }.
      to raise_error(ArgumentError, /isn't allowed/)
  end

  it 'is a 404 for a question no topic has' do
    get topic_question_path(topic.slug, 'nothing-here')
    expect(response).to have_http_status(:not_found)
  end

  it 'sends a question that a nation doesn’t list to that nation’s topic page' do
    nation, slug = Topics::Topic::NATIONS.each_key.lazy.filter_map { |each|
      shown = Topics::Guide.new(topic, each).entries.map(&:slug)
      missing = topic.questions.map(&:slug) - shown
      [each, missing.first] if missing.any?
    }.first
    skip 'every nation lists every question' unless slug
    get topic_question_path(topic.slug, slug, nation: nation)
    expect(response).to redirect_to(topic_path(topic.slug, nation: nation))
    follow_redirect!
    expect(page.text).to include('isn’t listed for')
  end

  it 'keeps a question when the nation changes, where that nation lists it' do
    entry = guide.entries.first
    get topic_question_path(topic.slug, entry.slug)
    Topics::Topic::NATIONS.each_key do |nation|
      link = page.css('.nation-tabs a').
             find { |tab| tab.text == Topics::Topic::NATIONS[nation] }
      listed = topic.questions.any? do |each|
        each.slug == entry.slug && each.useful_for?(nation)
      end
      place = nation unless nation == 'england'
      expected = if listed
                   topic_question_path(topic.slug, entry.slug, nation: place)
                 else
                   topic_path(topic.slug, nation: nation)
                 end
      expect(link['href']).to eq(expected), nation
    end
  end

  it 'sends the old addresses to the new pages, for the nation they named' do
    Topics::Topic::NATIONS.each_key do |nation|
      entries = Topics::Guide.new(topic, nation).entries
      next if entries.empty?

      place = nation unless nation == 'england'
      get topic_path(topic.slug, step: 'q-0', nation: nation)
      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(
        topic_question_path(topic.slug, entries.first.slug, nation: place)
      )
    end
    {
      { step: 'find' } => topic_path(topic.slug),
      { step: 'q-99' } => topic_path(topic.slug),
      { step: 'other' } => topic_holders_path(topic.slug),
      { step: 'other-1' } => topic_holders_path(topic.slug),
      { step: 'own' } => topics_path(step: 'own'),
      { step: 'fix' } => topics_path(step: 'fix'),
      { view: 'all' } => topic_path(topic.slug)
    }.each do |params, target|
      get topic_path(topic.slug, **params)
      expect(response).to redirect_to(target), params.inspect
    end
  end

  # The site's navigation already has Topics, selected on these pages.
  it 'has no Topics link in the band; a question links back to its topic' do
    get topic_path(topic.slug)
    expect(page.css('.page-band a').map(&:text)).not_to include('Topics')
    get topic_question_path(topic.slug, guide.entries.first.slug)
    expect(page.at('.page-band__back a').then { [_1.text, _1['href']] }).
      to eq([topic.title, "/topics/#{topic.slug}"])
  end

  it 'lists the topics first, then the routes that aren’t FOI, each on its own page' do
    get topics_path
    expect(page.css('.triage-screen h2').map(&:text)).
      to eq(['Find something out', 'Not for FOI'])
    expect(hrefs('.triage-replies--topics a')).
      to eq(Topics::Topic.all.map { "/topics/#{_1.slug}" })
    expect(hrefs('.triage-replies--topics ~ .triage-replies a')).
      to eq(['/topics?step=own', '/topics?step=fix'])
    get topics_path(step: 'own')
    expect(page.css('.triage-screen h2').text).
      to eq('For your own records, go direct')
    expect(page.at('.triage-screen__back a')['href']).to eq('/topics')
  end

  it 'needs no script on any of these pages' do
    get topic_path(topic.slug)
    expect(page.css('[data-controller="topic-steps"], template')).to be_empty
  end
end
