require 'spec_helper'

RSpec.describe 'Editing the topic content' do
  include_context 'with production error pages'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:policing) { TopicPage.find_by!(slug: 'policing') }
  let(:blank_nations) { { nations: [''] } }

  before { sign_in admin }

  def page
    Nokogiri::HTML(response.body)
  end

  def expect_saved(path)
    expect(response).to redirect_to(path)
    follow_redirect!
    expect(page.at('.alert-info').text).to include('It’s live on the site.')
  end

  it 'opens every form and list' do
    dataset = TopicDataset.find_by!(key: 'northmoor-recorded-crime')
    paths = [
      admin_topic_pages_path, new_admin_topic_page_path,
      admin_topic_datasets_path, new_admin_topic_dataset_path,
      edit_admin_topic_dataset_path(dataset), admin_topic_changes_path,
      new_admin_topic_page_topic_holder_path(policing),
      edit_admin_topic_page_topic_holder_path(policing, policing.holders.first),
      new_admin_topic_page_topic_question_path(policing),
      new_admin_topic_page_topic_source_path(policing),
      edit_admin_topic_page_topic_source_path(policing, policing.sources.first),
      new_admin_topic_page_topic_route_path(policing),
      edit_admin_topic_page_topic_route_path(policing, policing.routes.first)
    ]
    paths.each do |path|
      get path
      expect(response).to have_http_status(:ok), path
    end
  end

  describe 'topics' do
    it 'lists each topic with how many of each row it has' do
      get admin_topic_pages_path
      row = page.at('#topic-policing')
      expect(row.css('td').map(&:text)).
        to include('Policing', 'policing', '3', '2')
      expect(row.at('a')['href']).to eq(edit_admin_topic_page_path(policing))
    end

    it 'shows a topic’s form and a table of each kind of row' do
      get edit_admin_topic_page_path(policing)
      expect(page.at('#holders').text).to include('Caledon Police')
      expect(page.at('#questions').text).
        to include('How many burglaries were recorded?')
      expect(page.at('a[href="/topics/policing"]')).to be_present
    end

    it 'puts a change live on the next request, kept with the admin' do
      patch admin_topic_page_path(policing), params: {
        topic_page: { title: 'Police and crime', search: '',
                      titles: { scotland: 'Policing in Caledon', wales: '' },
                      refused: "Too costly\n\n  Exempt  \n" }
      }
      expect_saved(edit_admin_topic_page_path(policing))
      expect(policing.reload).to have_attributes(
        title: 'Police and crime', search: nil,
        titles: { 'scotland' => 'Policing in Caledon' },
        refused: ['Too costly', 'Exempt']
      )
      change = TopicChange.order(:id).last
      expect(change).to have_attributes(user: admin, action: 'update',
                                        record: policing)
      expect(change.changeset['title']).to eq(['Policing', 'Police and crime'])

      get topic_path('policing')
      expect(page.at('.page-band__title').text).to eq('Police and crime')
    end

    it 'shows the form again with the admin’s input when a save fails' do
      patch admin_topic_page_path(policing),
            params: { topic_page: { title: '', summary: 'My new summary' } }
      expect(response).to have_http_status(422)
      expect(page.at('#topic_page_summary').text.strip).to eq('My new summary')
      expect(page.at('.alert-error').text).
        to include("Title can't be blank")
      expect(policing.reload.summary).not_to eq('My new summary')
    end

    it 'adds a topic and deletes it' do
      post admin_topic_pages_path, params: {
        topic_page: { slug: 'libraries', title: 'Libraries',
                      summary: 'Opening hours and loans', position: '20' }
      }
      created = TopicPage.find_by!(slug: 'libraries')
      expect_saved(edit_admin_topic_page_path(created))
      get topic_path('libraries')
      expect(page.at('.page-band__title').text).to eq('Libraries')

      delete admin_topic_page_path(created)
      expect(response).to redirect_to(admin_topic_pages_path)
      expect(TopicPage.find_by(slug: 'libraries')).to be_nil
      get topic_path('libraries')
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses to delete one a topic guide names, saying why' do
      FactoryBot.create(:topic_guide,
                        dataset_id: nil, topic_slug: 'policing',
                        question_slug: 'how-many-burglaries-were-recorded')
      delete admin_topic_page_path(policing)
      expect(response).to redirect_to(edit_admin_topic_page_path(policing))
      follow_redirect!
      expect(page.at('.alert-error').text).to include(
        'a topic guide needs the question how-many-burglaries-were-recorded'
      )
      expect(TopicPage.exists?(policing.id)).to be(true)
    end
  end

  describe 'holders' do
    it 'adds one, dropping blank inputs and rows, then edits and deletes it' do
      post admin_topic_page_topic_holders_path(policing), params: {
        topic_holder: {
          position: '9', what: 'Police budgets', who: 'Northmoor Treasury',
          key: '', where: '', **blank_nations,
          to: { body: '', tag: 'treasury', url: '', wdtk: '' },
          groups: { '0' => { label: 'Treasuries', tag: 'treasury' },
                    '1' => { label: '', tag: '' } }
        }
      }
      expect_saved(edit_admin_topic_page_path(policing))
      holder = policing.holders.find_by!(who: 'Northmoor Treasury')
      expect(holder).to have_attributes(
        key: nil, where: nil, nations: [], to: { 'tag' => 'treasury' },
        groups: [{ 'label' => 'Treasuries', 'tag' => 'treasury' }]
      )

      patch admin_topic_page_topic_holder_path(policing, holder), params: {
        topic_holder: { nations: ['', 'scotland'],
                        to: { body: '', tag: '', url: '', wdtk: '' } }
      }
      expect(holder.reload).to have_attributes(nations: ['scotland'], to: nil)

      delete admin_topic_page_topic_holder_path(policing, holder)
      expect(response).to redirect_to(edit_admin_topic_page_path(policing))
      expect(TopicHolder.exists?(holder.id)).to be(false)
    end

    it 'refuses to delete one a question names, saying which' do
      holder = policing.holders.find_by!(who: 'Caledon Police')
      policing.questions.
        find_by!(slug: 'does-the-force-use-facial-recognition-cameras').
        update!(holder: { 'scotland' => 'Caledon Police' })
      delete admin_topic_page_topic_holder_path(policing, holder)
      expect(response).to redirect_to(
        edit_admin_topic_page_topic_holder_path(policing, holder)
      )
      follow_redirect!
      expect(page.at('.alert-error').text).to include(
        '“Does the force use facial recognition cameras?” (Policing, ' \
        'Scotland) needs the holder “Caledon Police”'
      )
      expect(TopicHolder.exists?(holder.id)).to be(true)
    end
  end

  describe 'questions' do
    let(:question) do
      policing.questions.find_by!(text: 'How many burglaries were recorded?')
    end

    it 'adds one with a dataset and holder in some nations' do
      post admin_topic_page_topic_questions_path(policing), params: {
        topic_question: {
          position: '4', text: 'How many cars were stolen?', slug: 'cars',
          keywords: "car theft\n", **blank_nations, partial: '0',
          ask: { tag: 'police' },
          dataset: { england: 'northmoor-recorded-crime', scotland: '' },
          holder: { england: 'Your police force', scotland: '' }
        }
      }
      expect_saved(edit_admin_topic_page_path(policing))
      created = policing.questions.find_by!(slug: 'cars')
      expect(created).to have_attributes(
        dataset: { 'england' => 'northmoor-recorded-crime' },
        holder: { 'england' => 'Your police force' },
        keywords: ['car theft'], partial: nil, ask: { 'tag' => 'police' }
      )
    end

    it 'is edited, keeping its slug, and deleted' do
      patch admin_topic_page_topic_question_path(policing, question), params: {
        topic_question: { text: 'How many homes were burgled?',
                          partial: '1', warning: '' }
      }
      slug = question.slug
      expect(question.reload).to have_attributes(
        text: 'How many homes were burgled?', slug: slug, partial: true,
        warning: nil
      )

      delete admin_topic_page_topic_question_path(policing, question)
      expect(TopicQuestion.exists?(question.id)).to be(false)
    end

    it 'shows its form with grouped dataset choices' do
      get edit_admin_topic_page_topic_question_path(policing, question)
      select = page.at('#topic_question_dataset_england')
      expect(select.at('option[selected]')['value']).
        to eq('northmoor-recorded-crime')
      expect(select.css('optgroup')).to be_present
    end
  end

  describe 'published sources and other routes' do
    it 'adds, edits and deletes a published source' do
      post admin_topic_page_topic_sources_path(policing), params: {
        topic_source: { position: '3', label: 'Arrests', note: '',
                        url: 'https://statistics.example/arrests',
                        **blank_nations }
      }
      expect_saved(edit_admin_topic_page_path(policing))
      source = policing.sources.find_by!(label: 'Arrests')
      expect(source.note).to be_nil

      patch admin_topic_page_topic_source_path(policing, source),
            params: { topic_source: { label: 'Arrests by force' } }
      expect(source.reload.label).to eq('Arrests by force')

      delete admin_topic_page_topic_source_path(policing, source)
      expect(TopicSource.exists?(source.id)).to be(false)
    end

    it 'adds, edits and deletes another route' do
      post admin_topic_page_topic_routes_path(policing), params: {
        topic_route: { position: '3', what: 'Thank an officer',
                       route: 'Write to the force',
                       to: { tag: 'police', body: '' }, **blank_nations }
      }
      expect_saved(edit_admin_topic_page_path(policing))
      route = policing.routes.find_by!(what: 'Thank an officer')
      expect(route.to).to eq('tag' => 'police')

      patch admin_topic_page_topic_route_path(policing, route),
            params: { topic_route: { route: 'Write to the chief constable' } }
      expect(route.reload.route).to eq('Write to the chief constable')

      delete admin_topic_page_topic_route_path(policing, route)
      expect(TopicRoute.exists?(route.id)).to be(false)
    end
  end

  describe 'datasets' do
    let(:fields) do
      { publisher: 'Northmoor Treasury', title: 'Police spending',
        url: 'https://treasury.example/police', kind: 'table',
        status: 'official', geography: '', area_codes: '', **blank_nations }
    end

    it 'filters the list by words, with how many questions use each' do
      get admin_topic_datasets_path, params: { query: 'recorded crime' }
      row = page.at('#dataset-northmoor-recorded-crime')
      expect(row.css('td').map(&:text)).to include('1')
      expect(page.at('#dataset-northmoor-police-response')).to be_nil
    end

    it 'adds, edits and deletes one' do
      post admin_topic_datasets_path,
           params: { topic_dataset: fields.merge(key: 'police-spending') }
      expect_saved(admin_topic_datasets_path)
      dataset = TopicDataset.find_by!(key: 'police-spending')
      expect(dataset.geography).to be_nil
      expect(Topics::Dataset.find('police-spending').title).
        to eq('Police spending')

      patch admin_topic_dataset_path(dataset),
            params: { topic_dataset: { title: 'Spending on police' } }
      expect(dataset.reload.title).to eq('Spending on police')

      delete admin_topic_dataset_path(dataset)
      expect(TopicDataset.exists?(dataset.id)).to be(false)
    end

    it 'refuses to delete one a question uses, saying which' do
      dataset = TopicDataset.find_by!(key: 'northmoor-recorded-crime')
      delete admin_topic_dataset_path(dataset)
      follow_redirect!
      expect(page.at('.alert-error').text).to include(
        '“How many burglaries were recorded?” (Policing, England) needs ' \
        'the dataset northmoor-recorded-crime'
      )
      expect(TopicDataset.exists?(dataset.id)).to be(true)
    end
  end

  describe 'the history' do
    it 'shows who changed what, filtered by topic' do
      patch admin_topic_page_path(policing),
            params: { topic_page: { summary: 'Crime and the police' } }
      health = TopicPage.find_by!(slug: 'health')
      patch admin_topic_page_path(health),
            params: { topic_page: { summary: 'Hospitals and waiting' } }

      get admin_topic_changes_path, params: { topic: policing.id }
      rows = page.css('tbody tr[id^="topic-change-"]')
      expect(rows.first.text).to include(admin.name, 'Topic', 'Policing',
                                         'Update', 'Crime and the police')
      expect(page.text).not_to include('Hospitals and waiting')
    end

    it 'says which changes no admin made came from the import' do
      policing.update!(summary: 'Typed at the console')
      TopicChange.create!(record: policing, action: 'update', imported: true,
                          changeset: { 'summary' => ['From the files', nil] })

      get admin_topic_changes_path, params: { topic: policing.id }
      who = page.css('tbody tr[id^="topic-change-"]').first(2).
            map { |row| row.at('td:nth-child(2)').text }
      expect(who).to eq(['Import', 'Command line'])
    end
  end
end
