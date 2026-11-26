require 'spec_helper'

RSpec.describe 'Batch request authority searches', type: :request do
  let(:pro_user) { FactoryBot.create(:pro_user) }
  let(:page) { Nokogiri::HTML(response.body) }

  def result_names
    page.css('.js-batch-authority-search-results-list-item ' \
             '.batch-builder__list__item__name').map { _1.text.strip }
  end

  def search_form_draft_id
    page.at_css('.js-batch-authority-search-form input[name="draft_id"]')
  end

  def summary
    page.at_css('.js-draft-batch-request-summary')
  end

  describe 'GET index' do
    let(:authority_1) { FactoryBot.create(:public_body) }
    let(:authority_2) { FactoryBot.create(:public_body) }
    let(:authority_3) { FactoryBot.create(:public_body) }
    let(:authorities) { [authority_1, authority_2, authority_3] }

    before do
      authorities
      sign_in pro_user
    end

    context 'without a draft_id param' do
      it 'starts a new draft, not yet saved' do
        expect { get alaveteli_pro_batch_request_authority_searches_path }.
          not_to change(AlaveteliPro::DraftInfoRequestBatch, :count)
        expect(response).to have_http_status(:ok)
        expect(search_form_draft_id).to be_nil
        expect(summary['data-draft-id']).to be_nil
        expect(summary.text).
          to include("You haven't added any authorities to your batch yet")
      end
    end

    context 'with a draft_id param' do
      it 'finds the draft by draft_id' do
        draft = FactoryBot.create(:draft_info_request_batch,
                                  user: pro_user, public_bodies: [authority_1])
        get alaveteli_pro_batch_request_authority_searches_path(
          draft_id: draft.id
        )
        expect(search_form_draft_id['value']).to eq(draft.id.to_s)
        expect(summary['data-draft-id']).to eq(draft.id.to_s)
        expect(summary.text).to include(authority_1.name)
      end

      it 'starts a new draft if none is found with the given draft_id' do
        max_id =
          AlaveteliPro::DraftInfoRequestBatch.maximum(:id).try(:next) || 99
        expect {
          get alaveteli_pro_batch_request_authority_searches_path(
            draft_id: max_id
          )
        }.not_to change(AlaveteliPro::DraftInfoRequestBatch, :count)
        expect(response).to have_http_status(:ok)
        expect(search_form_draft_id).to be_nil
        expect(summary['data-draft-id']).to be_nil
      end
    end

    context 'when responding to a normal request' do
      before do
        stub_typeahead_results(items: authorities)
        get alaveteli_pro_batch_request_authority_searches_path(
          authority_query: 'Example'
        )
      end

      it 'shows the search results in order' do
        expect(response).to have_http_status(:ok)
        expect(result_names).to eq(authorities.map(&:name))
      end

      it 'shows the query in the search box' do
        expect(page.at_css('#authority_query')['value']).to eq('Example')
      end

      it 'shows the first page of as many as were found' do
        expect(page.at_css('.batch-builder__list__page-info').text.squish).
          to eq('Page 1 of 1')
      end

      it 'renders the whole page' do
        expect(response.body).to include('<html')
        expect(page.at_css('.batch-builder__search-form')).to be_present
        expect(page.at_css('.batch-builder__chosen-authorities')).
          to be_present
      end

      # The successful search above shows the session is signed in.
      it 'is not found for pages beyond the limit' do
        expect(response).to have_http_status(:ok)
        get alaveteli_pro_batch_request_authority_searches_path(
          authority_query: 'Example Public Body', page: 21
        )
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when more were found than fit on a page' do
      before { stub_typeahead_results(items: authorities, total: 26) }

      it 'shows 25 a page' do
        get alaveteli_pro_batch_request_authority_searches_path(
          authority_query: 'Example'
        )
        expect(page.at_css('.batch-builder__list__page-info').text.squish).
          to eq('Page 1 of 2')
      end

      it 'shows 25 a page to an ajax request' do
        get alaveteli_pro_batch_request_authority_searches_path(
          authority_query: 'Example'
        ), xhr: true
        expect(page.at_css('.batch-builder__list__page-info').text.squish).
          to eq('Page 1 of 2')
      end
    end

    context 'when responding to an ajax request' do
      before do
        stub_typeahead_results(items: authorities)
        get alaveteli_pro_batch_request_authority_searches_path(
          authority_query: 'Example'
        ), xhr: true
      end

      it 'shows the search results in order' do
        expect(response).to have_http_status(:ok)
        expect(result_names).to eq(authorities.map(&:name))
      end

      it 'carries the query and page on each add button' do
        form = page.at_css('.js-add-authority-to-batch-form')
        expect(form.at_css('input[name="authority_query"]')['value']).
          to eq('Example')
        expect(form.at_css('input[name="page"]')['value']).to eq('1')
      end

      it 'shows the first page of as many as were found' do
        expect(page.at_css('.batch-builder__list__page-info').text.squish).
          to eq('Page 1 of 1')
      end

      it 'renders only the search results' do
        expect(response.body).not_to include('<html')
        expect(page.at_css('.js-batch-authority-search-results-list')).
          to be_present
        expect(page.at_css('.batch-builder__search-form')).to be_nil
      end

      # The successful search above shows the session is signed in.
      it 'is not found for pages beyond the limit' do
        expect(response).to have_http_status(:ok)
        get alaveteli_pro_batch_request_authority_searches_path(
          authority_query: 'Example Public Body', page: 21
        ), xhr: true
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'with an empty query' do
      it 'shows no results on the page' do
        get alaveteli_pro_batch_request_authority_searches_path
        expect(response).to have_http_status(:ok)
        expect(result_names).to be_empty
      end

      it 'shows no results to an ajax request' do
        get alaveteli_pro_batch_request_authority_searches_path(
          authority_query: ''
        ), xhr: true
        expect(response).to have_http_status(:ok)
        expect(result_names).to be_empty
      end
    end
  end

  describe 'GET new' do
    it 'redirects to the index' do
      sign_in pro_user
      get new_alaveteli_pro_batch_request_authority_search_path
      expect(response).to redirect_to(
        '/pro/batch_request_authority_searches'
      )
    end
  end

  # Browsing by category shows whenever there are authority categories, for
  # every account allowed to make batches; it does not come with a role.
  describe 'browsing by category' do
    before { sign_in FactoryBot.create(:user) }

    it 'is offered when there are authority categories' do
      FactoryBot.create(:category, :public_body)
      get alaveteli_pro_batch_request_authority_searches_path
      expect(response.body).to include('Browse by category')
    end

    it 'is not offered when there are none' do
      allow(PublicBody).to receive(:category_root).
        and_return(instance_double(Category, children: Category.none))
      get alaveteli_pro_batch_request_authority_searches_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Browse by category')
    end
  end
end
