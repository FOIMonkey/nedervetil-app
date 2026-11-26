require 'spec_helper'

RSpec.describe 'Topic guides' do
  include_context 'with production error pages'

  before do
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    allow(AlaveteliFeatures.backend).to receive(:enabled?).
      with(:alaveteli_pro).and_return(true)
  end

  let(:topic) { Topics::Topic.find('policing') }
  let(:burglaries) do
    topic.questions.find { |question| question.text.include?('burglaries') }
  end
  let(:question_path) { topic_question_path('policing', burglaries.slug) }

  def page
    Nokogiri::HTML(response.body)
  end

  it 'shows a published guide on each question its source answers' do
    FactoryBot.create(:topic_guide, title: 'Using the table',
                                    body: '<h1>Your area</h1><p>Find it.</p>')
    get question_path
    guide = page.at('.topic-guide')
    expect(guide.at('h2').text).to eq('Using the table')
    expect(guide.at('.topic-guide__body h3').text).to eq('Your area')
    expect(guide.at('.topic-guide__body h1')).to be_nil
    expect(page.at('.topic-guide__draft')).to be_nil
  end

  it 'gives a guide with no heading the usual one' do
    FactoryBot.create(:topic_guide, title: '')
    get question_path
    expect(page.at('.topic-guide h2').text).to eq('How it works')
  end

  it 'keeps a draft from visitors, and shows it to admins as a draft' do
    FactoryBot.create(:topic_guide, published: false)
    get question_path
    expect(page.at('.topic-guide')).to be_nil

    sign_in FactoryBot.create(:admin_user)
    get question_path
    expect(page.at('.topic-guide--draft .topic-guide__draft').text).
      to include('only admins can see this')
  end

  it 'strips what rich text mustn’t carry' do
    FactoryBot.create(:topic_guide,
                      body: '<p onclick="steal()">Hi <script>bad()</script>' \
                            '<a href="javascript:bad()">x</a></p>')
    get question_path
    body = page.at('.topic-guide__body').inner_html
    expect(body).not_to include('onclick', '<script', 'javascript:')
  end

  describe 'the admin pages' do
    before { sign_in FactoryBot.create(:admin_user) }

    it 'lists every source and question, with an Add or Edit for each' do
      guide = FactoryBot.create(:topic_guide, published: false)
      get admin_topic_guides_path
      expect(response).to have_http_status(:ok)
      row = page.at('#source-northmoor-recorded-crime')
      expect(row.text).to include('Draft', burglaries.text)
      expect(row.at('a[href$="/edit"]')['href']).
        to eq(edit_admin_topic_guide_path(guide))
      question = page.at("#question-policing-#{burglaries.slug}")
      expect(question.css('a').find { _1.text == 'Add guide' }['href']).
        to include("question_key=policing%2F#{burglaries.slug}")
    end

    it 'opens a question’s page in a nation that lists it' do
      health = Topics::Topic.find('health')
      agency = health.questions.find { _1.text.include?('health board') }
      get admin_topic_guides_path
      link = page.at("#question-health-#{agency.slug} a")
      expect(link['href']).
        to eq(topic_question_path('health', agency.slug, nation: 'scotland'))
    end

    it 'previews a source’s guide in the nation that uses the source' do
      homes = Topics::Topic.find('homes')
      homeless = homes.questions.find { _1.text.include?('homeless or in') }
      guide = FactoryBot.create(:topic_guide,
                                dataset_id: 'glenmoor-homelessness',
                                question_key: "homes/#{homeless.slug}")
      scotland = topic_question_path('homes', homeless.slug,
                                     nation: 'scotland')
      get edit_admin_topic_guide_path(guide)
      preview = page.css('a').find { _1.text.include?('question’s page') }
      expect(preview['href']).to eq(scotland)
      get admin_topic_guides_path
      expect(page.at('#source-glenmoor-homelessness a')['href']).to eq(scotland)
    end

    it 'groups the long lists, with the linked source already picked' do
      get new_admin_topic_guide_path(dataset_id: 'northmoor-recorded-crime')
      sources = page.at('#topic_guide_dataset_id')
      expect(sources.css('optgroup').map { _1['label'] }).
        to include(Topics::Dataset.find('northmoor-recorded-crime').publisher)
      expect(sources.at('option[selected]')['value']).
        to eq('northmoor-recorded-crime')
      groups = page.css('#topic_guide_question_key optgroup')
      expect(groups.map { _1['label'] }).to eq(Topics::Topic.all.map(&:title))
    end

    it 'adds, publishes and deletes a guide' do
      post admin_topic_guides_path, params: { topic_guide: {
        question_key: "policing/#{burglaries.slug}", published: '1',
        translations_attributes: { en: { locale: 'en', title: 'Read this',
                                         body: '<p>Pick your force.</p>' } }
      } }
      expect(response).to redirect_to(admin_topic_guides_path)
      guide = TopicGuide.last
      expect([guide.topic_slug, guide.question_slug, guide.published]).
        to eq(['policing', burglaries.slug, true])
      expect(guide.body.to_plain_text).to eq('Pick your force.')

      delete admin_topic_guide_path(guide)
      expect(TopicGuide.count).to eq(0)
    end

    it 'shows what is wrong with a guide for nothing' do
      post admin_topic_guides_path, params: { topic_guide: {
        translations_attributes: { en: { locale: 'en', body: '<p>x</p>' } }
      } }
      expect(response.status).to eq(422)
      expect(response.body).to include('Pick a source, a question, or both')
    end
  end

  it 'keeps the admin pages from anyone else' do
    sign_in FactoryBot.create(:user)
    get admin_topic_guides_path
    expect(response).not_to have_http_status(:ok)
  end
end
