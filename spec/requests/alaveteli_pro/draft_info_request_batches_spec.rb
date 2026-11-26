require 'spec_helper'

RSpec.describe 'Pro batch request drafts', type: :request do
  let(:pro_user) { FactoryBot.create(:pro_user) }
  let(:authority_1) { FactoryBot.create(:public_body) }
  let(:authority_2) { FactoryBot.create(:public_body) }
  let(:authority_3) { FactoryBot.create(:public_body) }
  let(:page) { Nokogiri::HTML(response.body) }

  # Signs in and checks it worked, so that a refusal which follows is the
  # page's own and not a failed sign-in.
  def summary
    page.at_css('.js-draft-batch-request-summary')
  end

  def summary_names
    summary.css('.batch-builder__list__item__name').map { _1.text.strip }
  end

  def expect_summary_alone
    expect(response.body).not_to include('<html')
    expect(summary).to be_present
    expect(page.at_css('.batch-builder__search-form')).to be_nil
  end

  shared_examples 'creating a request' do
    it 'creates a new DraftInfoRequestBatch' do
      expect { subject }.
        to change(AlaveteliPro::DraftInfoRequestBatch, :count).by 1
    end
  end

  shared_examples 'adding a body to a request' do
    it 'adds the body' do
      subject
      draft.reload
      expect(draft.public_bodies).to eq [authority_1]
    end

    context "if the user doesn't own the given draft" do
      let(:other_pro_user) { FactoryBot.create(:pro_user) }

      before do
        reset!
        sign_in other_pro_user
      end

      it 'adds the body to a new draft of their own instead' do
        expect { subject }.
          to change { other_pro_user.draft_info_request_batches.count }.by(1)
        new_draft = other_pro_user.draft_info_request_batches.last
        expect(new_draft).not_to eq(draft)
        expect(new_draft.public_bodies).to eq [authority_1]
        expect(draft.reload.public_bodies).to be_empty
      end
    end
  end

  shared_examples 'removing a body from a request' do
    it 'updates the given DraftInfoRequestBatch' do
      subject
      draft.reload
      expect(draft.public_bodies).to eq [authority_1]
    end

    context 'if the draft is left with no authorities' do
      before do
        draft.public_bodies.delete(authority_1)
      end

      it 'deletes the draft' do
        subject
        expect(AlaveteliPro::DraftInfoRequestBatch).not_to exist(draft.id)
      end
    end

    context "if the user doesn't own the given draft" do
      let(:other_pro_user) { FactoryBot.create(:pro_user) }

      before do
        reset!
        sign_in! other_pro_user
      end

      it 'is not found' do
        subject
        expect(response).to have_http_status(:not_found)
        expect(draft.reload.public_bodies).
          to match_array([authority_1, authority_2])
      end
    end
  end

  shared_examples 'respecting the selected page' do
    it 'respects the selected page if one is provided' do
      params[:authority_query] = 'Department'
      params[:page] = 2
      subject
      expected_path = alaveteli_pro_batch_request_authority_searches_path(
        draft_id: draft.id,
        authority_query: 'Department',
        page: 2,
        mode: 'search'
      )
      expect(response).to redirect_to(expected_path)
    end
  end

  describe 'with the batch permission' do
    before do
      sign_in pro_user
    end

    describe 'POST create' do
      let(:params) do
        {
          alaveteli_pro_draft_info_request_batch: {
            title: 'Test Batch Request',
            body: 'This is a test batch request.',
            public_body_ids: authority_1.id
          },
          authority_query: 'Department'
        }
      end

      let(:draft) { pro_user.draft_info_request_batches.first }

      describe 'when responding to a normal request' do
        subject do
          post alaveteli_pro_draft_info_request_batches_path, params: params
        end

        it_behaves_like 'creating a request'
        it_behaves_like 'respecting the selected page'

        it 'redirects to a new search if no query was provided' do
          params.delete(:authority_query)
          subject
          expected_path = alaveteli_pro_batch_request_authority_searches_path(
            draft_id: draft.id,
            mode: 'search'
          )
          expect(response).to redirect_to(expected_path)
        end

        it 'redirects to an existing search if a query is provided' do
          subject
          expected_path = alaveteli_pro_batch_request_authority_searches_path(
            draft_id: draft.id,
            authority_query: 'Department',
            mode: 'search'
          )
          expect(response).to redirect_to(expected_path)
        end

        it 'sets a :notice flash message' do
          subject
          expect(flash[:notice]).to eq 'Your Batch Request has been saved!'
        end
      end

      describe 'when responding to an AJAX request' do
        subject do
          post alaveteli_pro_draft_info_request_batches_path,
               params: params, xhr: true
        end

        it_behaves_like 'creating a request'

        it 'answers with the summary of the new draft alone' do
          subject
          expect_summary_alone
          expect(summary['data-draft-id']).to eq(draft.id.to_s)
          expect(summary_names).to eq([authority_1.name])
        end
      end
    end

    describe 'PUT update_bodies' do
      let(:draft) do
        FactoryBot.create(:draft_info_request_batch, user: pro_user)
      end

      describe 'when adding a body' do
        let(:params) do
          {
            alaveteli_pro_draft_info_request_batch: {
              draft_id: draft.id,
              public_body_id: authority_1.id,
              action: 'add'
            }
          }
        end

        describe 'when responding to a normal request' do
          subject do
            put update_bodies_alaveteli_pro_draft_info_request_batches_path,
                params: params
          end

          it_behaves_like 'adding a body to a request'

          it 'redirects to a new search if no query was provided' do
            subject
            expected_path =
              alaveteli_pro_batch_request_authority_searches_path(
                draft_id: draft.id,
                mode: 'search'
              )
            expect(response).to redirect_to(expected_path)
          end

          it 'redirects to an existing search if a query is provided' do
            params[:authority_query] = 'Department'
            subject
            expected_path =
              alaveteli_pro_batch_request_authority_searches_path(
                draft_id: draft.id,
                authority_query: 'Department',
                mode: 'search'
              )
            expect(response).to redirect_to(expected_path)
          end

          it_behaves_like 'respecting the selected page'

          it 'sets a :notice flash message' do
            subject
            expect(flash[:notice]).to eq 'Your Batch Request has been saved!'
          end
        end

        describe 'responding to an AJAX request' do
          subject do
            put update_bodies_alaveteli_pro_draft_info_request_batches_path,
                params: params, xhr: true
          end

          it_behaves_like 'adding a body to a request'

          it 'answers with the summary of the draft alone' do
            subject
            expect_summary_alone
            expect(summary['data-draft-id']).to eq(draft.id.to_s)
            expect(summary_names).to eq([authority_1.name])
          end
        end
      end

      describe 'when removing a body' do
        let(:params) do
          {
            alaveteli_pro_draft_info_request_batch: {
              draft_id: draft.id,
              public_body_id: authority_2.id,
              action: 'remove'
            }
          }
        end

        before do
          draft.public_bodies << [authority_1, authority_2]
        end

        describe 'when responding to a normal request' do
          subject do
            put update_bodies_alaveteli_pro_draft_info_request_batches_path,
                params: params
          end

          it_behaves_like 'removing a body from a request'

          it 'redirects to a new search if no query was provided' do
            subject
            expected_path =
              alaveteli_pro_batch_request_authority_searches_path(
                draft_id: draft.id,
                mode: 'search'
              )
            expect(response).to redirect_to(expected_path)
          end

          it 'redirects to an existing search if a query is provided' do
            params[:authority_query] = 'Department'
            subject
            expected_path =
              alaveteli_pro_batch_request_authority_searches_path(
                draft_id: draft.id,
                authority_query: 'Department',
                mode: 'search'
              )
            expect(response).to redirect_to(expected_path)
          end

          it_behaves_like 'respecting the selected page'

          it 'sets a :notice flash message if the draft is persisted' do
            subject
            expect(flash[:notice]).to eq 'Your Batch Request has been saved!'
          end

          it 'redirects without the draft_id if the draft is not persisted' do
            draft.public_bodies.delete(authority_1)
            subject
            expected_path =
              alaveteli_pro_batch_request_authority_searches_path(
                mode: 'search'
              )
            expect(response).to redirect_to(expected_path)
          end

          it 'sets no :notice flash message if the draft is not persisted' do
            draft.public_bodies.delete(authority_1)
            subject
            expect(flash[:notice]).to be_nil
          end
        end

        describe 'responding to an AJAX request' do
          subject do
            put update_bodies_alaveteli_pro_draft_info_request_batches_path,
                params: params, xhr: true
          end

          it_behaves_like 'removing a body from a request'

          it 'answers with the summary of the draft alone' do
            subject
            expect_summary_alone
            expect(summary['data-draft-id']).to eq(draft.id.to_s)
            expect(summary_names).to eq([authority_1.name])
          end
        end
      end
    end

    describe 'PUT update' do
      let(:draft) do
        FactoryBot.create(:draft_info_request_batch, user: pro_user)
      end
      let(:params) do
        {
          alaveteli_pro_draft_info_request_batch: {
            title: 'Test Batch Request',
            body: 'This is a test batch request.',
            public_body_ids: [authority_1.id, authority_2.id, authority_3.id]
          }
        }
      end
      let(:action) do
        put alaveteli_pro_draft_info_request_batch_path(draft), params: params
      end

      it 'updates the draft' do
        action
        draft.reload
        expect(draft.title).to eq 'Test Batch Request'
        expect(draft.body).to eq 'This is a test batch request.'
        expect(draft.public_bodies).to match_array(
          [authority_1, authority_2, authority_3]
        )
      end

      context 'when the summary is too long to send' do
        before do
          params[:alaveteli_pro_draft_info_request_batch][:title] = 'x' * 300
        end

        it 'keeps what was typed, the summary included' do
          action
          draft.reload
          expect(draft.title).to eq('x' * 300)
          expect(draft.body).to eq 'This is a test batch request.'
          expect(draft.public_bodies).to match_array(
            [authority_1, authority_2, authority_3]
          )
        end
      end

      context 'when the user is previewing' do
        before do
          params[:preview] = '1'
        end

        it 'redirects to the batch preview page' do
          action
          expected_path = preview_new_alaveteli_pro_info_request_batch_path(
            draft_id: draft.id
          )
          expect(response).to redirect_to(expected_path)
        end
      end

      context 'when the user is saving' do
        it 'redirects to the new batch page' do
          action
          expected_path = new_alaveteli_pro_info_request_batch_path(
            draft_id: draft.id
          )
          expect(response).to redirect_to(expected_path)
        end
      end
    end
  end

  # The batch permission alone decides, as on the batch pages; a role
  # doesn't matter.
  describe 'who may make a batch draft' do
    include_context 'with request limits on'

    let(:user) { FactoryBot.create(:user) }
    let(:params) do
      {
        alaveteli_pro_draft_info_request_batch: {
          title: 'Grit bin sites',
          body: 'Where are the grit bins?',
          public_body_ids: FactoryBot.create(:public_body).id
        }
      }
    end

    it 'lets an account with the batch permission, without a role' do
      user.update!(trusted: true)
      sign_in user
      expect {
        post alaveteli_pro_draft_info_request_batches_path, params: params
      }.to change(AlaveteliPro::DraftInfoRequestBatch, :count).by(1)
    end

    it 'turns away an account without the batch permission' do
      sign_in! user
      expect {
        post alaveteli_pro_draft_info_request_batches_path, params: params
      }.not_to change(AlaveteliPro::DraftInfoRequestBatch, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
