require 'spec_helper'

RSpec.describe 'Pro batch request pages', type: :request do
  let(:body_1) { FactoryBot.create(:public_body) }
  let(:body_2) { FactoryBot.create(:public_body) }
  let(:bodies) { [body_1, body_2] }
  let(:user) { FactoryBot.create(:pro_user) }
  let(:other_user) { FactoryBot.create(:pro_user) }
  let!(:draft) do
    FactoryBot.create(:draft_info_request_batch,
                      public_bodies: bodies,
                      body: 'Dear [Authority name], where are the grit ' \
                            'bins? Thanks, Alice',
                      user: user)
  end
  let(:params) { { draft_id: draft.id } }
  let(:page) { Nokogiri::HTML(response.body) }

  # Signs in and checks it worked, so that a refusal which follows is the
  # page's own and not a failed sign-in.
  def heading
    page.at_css('h1.page-band__title').text
  end

  def error_messages
    page.css('#errorExplanation li').map { _1.text.strip }
  end

  def recipients_link
    page.at_css("a[href='#{alaveteli_pro_batch_request_authority_searches_path(
      draft_id: draft.id
    )}']")
  end

  def expect_writing_page_with_errors
    expect(heading).to include('Make a batch request')
    expect(error_messages).to eq(
      ['Please enter a summary of your request',
       'Please enter your letter requesting information']
    )
  end

  def expect_existing_batch_warning
    expect(response.body).to include('You have already sent this request')
    link = "a[href='#{info_request_batch_path(existing_batch)}']"
    expect(page.at_css(link)).to be_present
  end

  shared_examples 'a page for the draft batch' do
    context 'if the current_user is banned' do
      # A suspended account doesn't act (Ability), so it may not create a
      # batch, and the batch pages aren't there for it.
      before do
        user.update!(ban_text: 'banned')
        sign_in! user
      end

      it 'is not found' do
        expect { action }.not_to change(InfoRequestBatch, :count)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "if the specified draft doesn't exist" do
      it 'is not found' do
        sign_in! user
        params[:draft_id] = AlaveteliPro::DraftInfoRequestBatch.
          maximum(:id).next
        action
        expect(response).to have_http_status(:not_found)
      end
    end

    context "if the current_user doesn't own the specified draft" do
      it 'is not found' do
        sign_in! other_user
        expect { action }.not_to change(InfoRequestBatch, :count)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET new' do
    let(:action) { get new_alaveteli_pro_info_request_batch_path(params) }

    it_behaves_like 'a page for the draft batch'

    context 'when signed in as the owner of the draft' do
      before do
        sign_in user
        action
      end

      it 'shows the batch writing page' do
        expect(response).to have_http_status(:ok)
        expect(heading).to include('Make a batch request')
      end

      it 'is a form to save the draft named by draft_id' do
        form = page.at_css('form#write_form')
        expect(form['action']).
          to eq(alaveteli_pro_draft_info_request_batch_path(draft))
        expect(form.at_css('#alaveteli_pro_draft_info_request_batch_title')[
          'value'
        ]).to eq(draft.title)
        expect(form.at_css('#alaveteli_pro_draft_info_request_batch_body').
          text.strip).to eq(draft.body)
      end

      it 'is addressed to every authority in the draft' do
        ids = page.css(
          'input[name="alaveteli_pro_draft_info_request_batch' \
          '[public_body_ids][]"]'
        ).map { _1['value'].to_i }
        expect(ids).to match_array(bodies.map(&:id))
        expect(page.at_css('#to_public_body').text).to include('2 recipients')
        expect(recipients_link).to be_present
      end
    end
  end

  describe 'GET preview' do
    let(:action) do
      get preview_new_alaveteli_pro_info_request_batch_path(params)
    end

    it_behaves_like 'a page for the draft batch'

    context 'when everything is valid' do
      before do
        sign_in user
        action
      end

      it 'shows the batch preview' do
        expect(response).to have_http_status(:ok)
        expect(heading).to include('Preview new batch request')
        expect(response.body).not_to include('You have already sent')
      end

      it 'shows the batch made from the draft' do
        expect(page.at_css('.preview_subject').text).to include(draft.title)
        expect(page.at_css('.preview_to').text).to include('2 recipients')
        expect(recipients_link).to be_present
      end

      it "shows the letter as one authority's request will have it" do
        letter = page.at_css('.correspondence_text').text
        salutations = bodies.map { "Dear #{_1.name}," }
        expect(salutations.count { letter.include?(_1) }).to eq(1)
        expect(letter).to include('where are the grit bins? Thanks, Alice')
        expect(letter).not_to include('[Authority name]')
      end

      it 'is a form to send the batch from the draft' do
        form = page.at_css("form[action='#{
          alaveteli_pro_info_request_batches_path
        }']")
        expect(form.at_css('input[name="draft_id"]')['value']).
          to eq(draft.id.to_s)
      end
    end

    context 'when the draft is a duplicate' do
      let!(:existing_batch) do
        FactoryBot.create(
          :info_request_batch,
          title: draft.title, body: draft.body,
          public_bodies: draft.public_bodies, user: draft.user
        )
      end

      it 'shows the preview, warning of the existing batch' do
        sign_in user
        action
        expect(heading).to include('Preview new batch request')
        expect_existing_batch_warning
      end
    end

    context 'when the draft is not valid' do
      before do
        draft.update!(body: '', title: '')
        sign_in user
        action
      end

      it 'shows the writing page with each error once' do
        expect_writing_page_with_errors
      end
    end
  end

  describe 'POST create' do
    let(:action) do
      post alaveteli_pro_info_request_batches_path, params: params
    end

    shared_examples 'when batch is created' do
      before { sign_in user }

      it 'creates an info_request_batch' do
        expect { action }.to change(InfoRequestBatch, :count).by(1)
        new_batch = InfoRequestBatch.order(created_at: :desc).first
        expect(new_batch.title).to eq draft.title
        expect(new_batch.public_bodies).to match_array(bodies)
        expect(new_batch.body).to eq draft.body
      end

      it 'destroys the draft' do
        expect { action }.
          to change(AlaveteliPro::DraftInfoRequestBatch, :count).by(-1)
        expect(AlaveteliPro::DraftInfoRequestBatch).not_to exist(draft.id)
      end

      it 'sets batch_sent flash' do
        action
        expect(flash[:batch_sent]).to eq(true)
      end

      it 'redirects to show the batch' do
        action
        new_batch = InfoRequestBatch.order(created_at: :desc).first
        expect(response).
          to redirect_to(show_alaveteli_pro_batch_request_path(new_batch.id))
      end
    end

    it_behaves_like 'a page for the draft batch'

    context 'when everything is valid' do
      include_examples 'when batch is created'
    end

    context 'when the draft is a duplicate' do
      let!(:existing_batch) do
        FactoryBot.create(
          :info_request_batch,
          title: draft.title, body: draft.body,
          public_bodies: draft.public_bodies, user: draft.user
        )
      end

      it 'shows the preview again, warning of the existing batch' do
        sign_in user
        expect { action }.not_to change(InfoRequestBatch, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(heading).to include('Preview new batch request')
        expect_existing_batch_warning
      end
    end

    context 'when the existing batch has been ignored' do
      let(:params) { { draft_id: draft.id, ignore_existing_batch: true } }
      let!(:existing_batch) do
        FactoryBot.create(
          :info_request_batch,
          title: draft.title, body: draft.body,
          public_bodies: draft.public_bodies, user: draft.user
        )
      end

      include_examples 'when batch is created'

      it 'keeps the existing batch alongside the new one' do
        sign_in user
        action
        expect(InfoRequestBatch).to exist(existing_batch.id)
        expect(user.info_request_batches.where(title: draft.title).count).
          to eq(2)
      end
    end

    context 'when the draft is not valid' do
      before do
        draft.update!(body: '', title: '')
        sign_in user
      end

      it 'shows the writing page with each error once' do
        expect { action }.not_to change(InfoRequestBatch, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect_writing_page_with_errors
      end
    end
  end
end
