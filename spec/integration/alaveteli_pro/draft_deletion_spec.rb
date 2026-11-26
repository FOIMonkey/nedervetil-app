require 'spec_helper'

RSpec.describe 'Deleting a draft request', type: :request do
  let(:user) { FactoryBot.create(:user, name: 'Draft Writer') }
  let(:drafts_list) do
    alaveteli_pro_info_requests_path(
      'alaveteli_pro_request_filter[filter]' => 'draft'
    )
  end

  def create_draft(account)
    FactoryBot.create(:draft_info_request, user: account,
                                           title: 'Grit bin sites',
                                           body: 'Where are the grit bins?')
  end

  context 'when signed in' do
    before { sign_in(user) }

    it 'removes the draft and its summary, and says so on the drafts list' do
      draft = create_draft(user)
      summary = draft.request_summary

      delete "/pro/draft_info_requests/#{draft.id}"

      expect(DraftInfoRequest.exists?(draft.id)).to be(false)
      expect(AlaveteliPro::RequestSummary.exists?(summary.id)).to be(false)
      expect(response).to redirect_to(drafts_list)
      follow_redirect!
      expect(response.body).to include('Draft deleted.')
    end

    it "leaves another account's draft, answering as for an unknown id" do
      other = FactoryBot.create(:user, name: 'Other Account')
      draft = create_draft(other)

      delete "/pro/draft_info_requests/#{draft.id}"
      expect(DraftInfoRequest.exists?(draft.id)).to be(true)
      expect(response).to redirect_to(drafts_list)
      theirs = [response.status, response.location, flash[:notice]]

      delete "/pro/draft_info_requests/#{DraftInfoRequest.maximum(:id) + 1}"
      expect([response.status, response.location, flash[:notice]]).
        to eq(theirs)
    end

    it 'answers a second delete of the same draft without an error' do
      draft = create_draft(user)

      2.times { delete "/pro/draft_info_requests/#{draft.id}" }

      expect(response).to redirect_to(drafts_list)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it 'deletes a draft carried across sign-in, freeing the pending letter' do
      draft = create_draft(user)
      carried = PendingRequestDraft.capture(
        {}, title: draft.title, body: draft.body,
            public_body_id: draft.public_body_id
      )
      carried.update!(draft_info_request: draft)

      delete "/pro/draft_info_requests/#{draft.id}"

      expect(DraftInfoRequest.exists?(draft.id)).to be(false)
      expect(carried.reload.draft_info_request_id).to be_nil
    end
  end

  it 'asks a signed-out visitor to sign in and keeps the draft' do
    draft = create_draft(user)

    delete "/pro/draft_info_requests/#{draft.id}"

    expect(response).to redirect_to(%r{/profile/sign_in})
    expect(DraftInfoRequest.exists?(draft.id)).to be(true)
  end
end
