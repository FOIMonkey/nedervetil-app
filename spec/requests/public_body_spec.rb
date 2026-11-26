require 'spec_helper'

RSpec.describe 'Authority pages', type: :request do
  # Parsed afresh, as an example may make several requests.
  def page
    Nokogiri::HTML(response.body)
  end

  def body_title
    page.at_css('h1.page-band__title')&.text
  end

  describe 'showing a body' do
    include PublicationFeedHelpers

    it 'should be successful, showing the documents page' do
      get show_public_body_path(url_name: 'dfh')
      expect(response).to be_successful
      expect(page.at_css('.body-hub')).to be_present
    end

    it 'links no home page, scheme or log stored before they were checked' do
      body = public_bodies(:humpadink_public_body)
      body.update_column(:home_page,
                         'javascript:alert(1)//http://example.org')
      body.translations.update_all(publication_scheme: 'javascript:alert(2)',
                                   disclosure_log: 'javascript:alert(3)')
      get show_public_body_path(url_name: body.url_name)
      expect(page.css('a[href^="javascript"]')).to be_empty
      expect(response.body).not_to include('Visit website')
    end

    it 'shows the body' do
      get show_public_body_path(url_name: 'dfh')
      expect(body_title).to eq(public_bodies(:humpadink_public_body).name)
    end

    it 'shows its published documents, not its requests' do
      document = make_feed_document
      get show_public_body_path(url_name: @feed_authority.url_name)
      expect(body_title).to eq(@feed_authority.name)
      published = page.at_css('section[aria-labelledby="body-here"]')
      expect(published.css('.document-result__title').map(&:text)).
        to eq([document.title])
      expect(response.body).not_to include('Private source marker')

      get show_public_body_path(url_name: 'tgq')
      expect(body_title).to eq(public_bodies(:geraldine_public_body).name)
      expect(page.at_css('section[aria-labelledby="body-here"]')).to be_nil
      expect(response.body).not_to include(document.title)
    end

    it 'should display the body using same locale as that used in url_name' do
      cookies[:locale] = 'es'
      get show_public_body_path(url_name: 'edfh')
      expect(page.text).to include('Baguette')
    end

    it 'should show public body names in the selected locale language if ' \
       'present for a locale with underscores' do
      AlaveteliLocalization.set_locales('he_IL en', 'en')
      cookies[:locale] = 'he_IL'
      get show_public_body_path(url_name: 'dfh')
      expect(page.text).to include('Hebrew Humpadinking')
    end

    it 'should redirect use to the relevant locale even when url_name is ' \
       'for a different locale' do
      get show_public_body_path(url_name: 'edfh')
      expect(response).to redirect_to('/body/dfh')
    end

    it 'should redirect to newest name if you use historic name of public ' \
       'body in URL' do
      get show_public_body_path(url_name: 'hdink')
      expect(response).to redirect_to('/body/dfh')
    end

    it 'should redirect to lower case name if you use mixed case name in URL' do
      get show_public_body_path(url_name: 'dFh')
      expect(response).to redirect_to('/body/dfh')
    end

    it 'should show high page offsets of its published documents' do
      get show_public_body_path(url_name: 'dfh', page: 25)
      expect(response).to be_successful
      expect(body_title).to eq(public_bodies(:humpadink_public_body).name)
    end

    it 'should not raise an error when given an empty query param' do
      get show_public_body_path(url_name: 'dfh', query: '')
      expect(response).to be_successful
      expect(body_title).to eq(public_bodies(:humpadink_public_body).name)
    end
  end

  describe 'listing bodies' do
    def make_single_language_example(locale)
      result = nil
      with_default_locale(locale) do
        AlaveteliLocalization.with_locale(locale) do
          case locale
          when :en
            result = PublicBody.new(name: 'English only',
                                    short_name: 'EO')
          when :es
            result = PublicBody.new(name: 'Español Solamente',
                                    short_name: 'ES')
          when :en_GB
            result = PublicBody.new(name: 'GB English',
                                    short_name: 'GB')
          else
            raise StandardError, "Unknown locale #{locale}"
          end
          result.request_email = "#{locale}@example.org"
          result.last_edit_editor = 'test'
          result.last_edit_comment = ''
          result.save!
        end
      end
      result
    end

    def listed_names
      page.css('.body_listing .head a').map { _1.text.strip }
    end

    def description
      page.at_css('h2.publicbody_results').text.strip
    end

    def names_of(*fixtures)
      fixtures.map { public_bodies(_1).name }
    end

    # The SQL run while the block runs.
    def queries_during
      queries = []
      record = ->(*, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.
        subscribed(record, 'sql.active_record') { yield }
      queries
    end

    def listing_queries
      queries_during { get list_public_bodies_path }.
        grep(/SELECT.*public_bodies/m)
    end

    let(:all_bodies) do
      names_of(:other_public_body, :humpadink_public_body,
               :forlorn_public_body, :geraldine_public_body,
               :sensible_walks_public_body, :silly_walks_public_body)
    end

    it 'should be successful' do
      get list_public_bodies_path
      expect(response).to be_successful
      expect(page.at_css('#search_form')).to be_present
    end

    it 'with no fallback, should only return bodies from the current locale' do
      english_only = make_single_language_example :en
      make_single_language_example :es
      cookies[:locale] = 'es'
      get list_public_bodies_path
      expect(listed_names).not_to include(english_only.name)
      expect(listed_names).to include('Español Solamente')
    end

    it 'if fallback is requested, should list all bodies from default ' \
       'locale, even when there are no translations for selected locale' do
      allow(AlaveteliConfiguration).
        to receive(:public_body_list_fallback_to_default_locale).
        and_return(true)
      english_only = make_single_language_example :en
      cookies[:locale] = 'es'
      get list_public_bodies_path
      expect(listed_names).to include(english_only.name)
    end

    it 'if fallback is requested, should still list public bodies only ' \
       'with translations in the current locale' do
      allow(AlaveteliConfiguration).
        to receive(:public_body_list_fallback_to_default_locale).
        and_return(true)
      make_single_language_example :es
      cookies[:locale] = 'es'
      get list_public_bodies_path
      expect(listed_names).to include('Español Solamente')
    end

    it 'if fallback is requested, make sure that there are no duplicates ' \
       'listed' do
      allow(AlaveteliConfiguration).
        to receive(:public_body_list_fallback_to_default_locale).
        and_return(true)
      cookies[:locale] = 'es'
      get list_public_bodies_path
      hrefs = page.css('.body_listing .head a').map { _1['href'] }
      expect(hrefs).not_to be_empty
      expect(hrefs).to eq(hrefs.uniq)
    end

    it 'should show public body names in the selected locale language if ' \
       'present' do
      cookies[:locale] = 'es'
      get list_public_bodies_path
      expect(page.text).to include('El Department for Humpadinking')
    end

    it 'show public body names of the selected underscore locale language' do
      AlaveteliLocalization.set_locales('en en_GB', 'en')
      gb_only = make_single_language_example :en_GB
      cookies[:locale] = 'en_GB'
      get list_public_bodies_path
      expect(page.text).to include(gb_only.name)
    end

    it 'should not show the internal admin authority' do
      PublicBody.internal_admin_body
      cookies[:locale] = 'en'
      get list_public_bodies_path
      expect(page.text).not_to include('Internal admin authority')
    end

    it 'should order on the translated name, even with the fallback' do
      allow(AlaveteliConfiguration).
        to receive(:public_body_list_fallback_to_default_locale).
        and_return(true)
      cookies[:locale] = 'es'
      get list_public_bodies_path
      expect(listed_names).not_to be_empty
      expect(listed_names).to eq(listed_names.sort)
    end

    it 'should show public body names in the selected locale language if ' \
       'present for a locale with underscores' do
      AlaveteliLocalization.set_locales('he_IL en', 'en')
      cookies[:locale] = 'he_IL'
      get list_public_bodies_path
      expect(page.text).to include('Hebrew Humpadinking')
    end

    it 'should list bodies in alphabetical order' do
      # Note that they are alphabetised by localised name
      get list_public_bodies_path
      expect(response).to have_http_status(:ok)
      expect(listed_names).to eq(all_bodies)
      expect(description).to eq('Found 6 public authorities')
      expect(page.at_css('.alphabet__letter--current')).to be_nil
    end

    it 'list bodies in collate order according to the locale with the ' \
       'fallback set' do
      allow(AlaveteliConfiguration).
        to receive(:public_body_list_fallback_to_default_locale).
        and_return(true)

      allow(DatabaseCollation).to receive(:supports?).
        with(an_instance_of(String)).
          and_return(true)

      cookies[:locale] = 'en_GB'
      expect(listing_queries.join("\n")).to include('COLLATE')
      expect(listed_names).not_to be_empty
    end

    it 'list bodies in default order according to the locale with the ' \
       'fallback set' do
      allow(AlaveteliConfiguration).
        to receive(:public_body_list_fallback_to_default_locale).
        and_return(true)

      allow(DatabaseCollation).to receive(:supports?).
        with(an_instance_of(String)).
          and_return(false)

      cookies[:locale] = 'unknown'
      queries = listing_queries
      expect(queries).not_to be_empty
      expect(queries.join("\n")).not_to include('COLLATE')
      expect(listed_names).not_to be_empty
    end

    it 'list bodies in collate order according to the locale' do
      allow(AlaveteliConfiguration).
        to receive(:public_body_list_fallback_to_default_locale).
        and_return(false)

      allow(DatabaseCollation).to receive(:supports?).
        with(an_instance_of(String)).
          and_return(true)

      AlaveteliLocalization.set_locales('en en_GB', 'en')
      gb_only = make_single_language_example :en_GB
      cookies[:locale] = 'en_GB'
      expect(listing_queries.join("\n")).to include('COLLATE')
      expect(listed_names).to eq([gb_only.name])
    end

    it 'list bodies in alphabetical order according to the locale' do
      allow(AlaveteliConfiguration).
        to receive(:public_body_list_fallback_to_default_locale).
        and_return(false)

      allow(DatabaseCollation).to receive(:supports?).
        with(an_instance_of(String)).
          and_return(false)

      cookies[:locale] = 'unknown'
      queries = listing_queries
      expect(queries).not_to be_empty
      expect(queries.join("\n")).not_to include('COLLATE')
      expect(listed_names).not_to be_empty
    end

    it 'should support simple searching of bodies by title' do
      get list_public_bodies_path(public_body_query: 'quango')
      expect(listed_names).to eq(names_of(:geraldine_public_body))
    end

    it 'should support simple searching of bodies by short_name' do
      get list_public_bodies_path(public_body_query: 'DfH')
      expect(listed_names).to eq(names_of(:humpadink_public_body))
    end

    xit 'should support simple searching of bodies by notes' do
      get list_public_bodies_path(public_body_query: 'Albatross')
      expect(listed_names).to eq(names_of(:humpadink_public_body))
    end

    it 'should list bodies in alphabetical order with different locale' do
      with_default_locale(:es) do
        get list_public_bodies_path
        expect(response).to have_http_status(:ok)
        expected = AlaveteliLocalization.with_locale(:es) do
          names_of(:geraldine_public_body, :humpadink_public_body)
        end
        expect(listed_names).to eq(expected)
        expect(description).to eq('Found 2 public authorities')
      end
    end

    it 'should list a tagged thing on the appropriate list page, and ' \
       'others on the other page, and all still on the all page' do
      category = FactoryBot.create(:category, :public_body,
                                   category_tag: 'dink')
      public_bodies(:humpadink_public_body).tag_string =
        category.category_tag

      get list_public_bodies_by_tag_path(category.category_tag)
      expect(response).to have_http_status(:ok)
      expect(listed_names).to eq(names_of(:humpadink_public_body))
      expect(page.text).
        to include("Found 1 public authority in the category " \
                   "‘#{category.title}’")

      get list_public_bodies_by_tag_path('other')
      expect(response).to have_http_status(:ok)
      expect(listed_names).
        to eq(names_of(:other_public_body, :sensible_walks_public_body))

      get list_public_bodies_path
      expect(response).to have_http_status(:ok)
      expect(listed_names).to eq(all_bodies)
    end

    it 'should list a machine tagged thing, should get it in both ways' do
      public_bodies(:humpadink_public_body).tag_string = 'eats_cheese:stilton'

      get list_public_bodies_by_tag_path('eats_cheese')
      expect(listed_names).to eq(names_of(:humpadink_public_body))
      expect(description).
        to eq('Found 1 public authority matching the tag ‘eats_cheese’')

      get list_public_bodies_by_tag_path('eats_cheese:jarlsberg')
      expect(listed_names).to eq([])
      expect(page.text).to include('None found.')
      expect(description).
        to eq('Found 0 public authorities matching the tag ' \
              '‘eats_cheese:jarlsberg’')

      get list_public_bodies_by_tag_path('eats_cheese:stilton')
      expect(listed_names).to eq(names_of(:humpadink_public_body))
      expect(description).
        to eq('Found 1 public authority matching the tag ' \
              '‘eats_cheese:stilton’')
    end

    it 'should not show a request count' do
      fake_pb = FactoryBot.create(:public_body)
      FactoryBot.create(:info_request, prominence: 'hidden',
                                       public_body: fake_pb)
      FactoryBot.create(:info_request, public_body: fake_pb)
      expect(fake_pb.reload.info_requests.size).to eq(2)
      get list_public_bodies_path
      expect(listed_names).to include(fake_pb.name)
      expect(response.body).not_to match(/\d+ requests?\./)
    end

    it 'refuses a json version of a list as an unknown format' do
      get list_public_bodies_path(format: 'json')
      expect(response).to have_http_status(:not_acceptable)
    end

    it 'should list authorities starting with a multibyte first letter' do
      AlaveteliLocalization.set_locales('cs', 'cs')

      authority = AlaveteliLocalization.with_locale(:cs) do
        FactoryBot.create(:public_body, name: 'Åčçèñtéd Authority')
      end

      cookies[:locale] = 'cs'
      get list_public_bodies_by_tag_path('å')
      expect(response).to have_http_status(:ok)
      expect(listed_names).to eq([authority.name])
      expect(description).
        to eq('Found 1 public authority beginning with ‘Å’')
    end
  end

  describe 'showing JSON version for API' do
    it 'should redirect to its published documents as JSON' do
      get show_public_body_path(url_name: 'dfh', format: 'json')
      expect(response).
        to redirect_to(disclosure_documents_path(body: 'dfh', format: 'json'))
    end
  end

  describe 'exporting public bodies as CSV' do
    before do
      allow(Rails.root).to receive(:join).and_call_original
      allow(Rails.root).to receive(:join).with('cache', 'all-authorities.csv').
        and_return(fixture)
    end

    context 'with cached CSV' do
      let(:fixture) do
        Rails.root.join('spec', 'fixtures', 'all-authorities.csv')
      end

      it 'sends CSV file as response' do
        get all_public_bodies_csv_path
        expect(response.body).to eq File.binread(fixture)
      end
    end

    context 'without cached CSV' do
      let(:fixture) { Rails.root.join('spec', 'fixtures', 'missing.csv') }

      it 'respond with 204 "no content" status' do
        get all_public_bodies_csv_path
        expect(response.status).to eq 204
      end
    end
  end

  describe 'type ahead searches' do
    it 'returns a 400 bad request status code without a query param' do
      get search_ahead_bodies_path
      expect(response.status).to eq(400)
    end

    it 'renders the search ahead results alone' do
      get search_ahead_bodies_path(query: '')
      expect(response).to have_http_status(:ok)
      expect(page.at_css('turbo-frame#typeahead_response')).to be_present
      expect(response.body).not_to include('<html')
    end

    it 'shows the matching bodies' do
      public_body_1 = public_bodies(:geraldine_public_body)
      public_body_2 = public_bodies(:humpadink_public_body)
      stub_typeahead_results(items: [public_body_1, public_body_2])
      get search_ahead_bodies_path(query: 'Geraldine Humpadinking')
      results = page.css('#authority_search_ahead_results .head a').
        map { _1.text.strip }
      expect(results).to eq([public_body_1.name, public_body_2.name])
    end

    it 'shows the number of bodies matching the keywords' do
      public_body_1 = public_bodies(:geraldine_public_body)
      public_body_2 = public_bodies(:humpadink_public_body)
      stub_typeahead_results(items: [public_body_1, public_body_2])
      get search_ahead_bodies_path(query: 'Geraldine Humpadinking')
      expect(response.body).to match('2 matching authorities')
    end

    it 'sets no cookie for a signed-out visitor' do
      get search_ahead_bodies_path, params: { query: 'Quango' }
      expect(response).to have_http_status(:ok)
      expect(response.headers['Set-Cookie']).to be_blank
    end
  end
end
