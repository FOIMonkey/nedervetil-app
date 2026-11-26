require 'spec_helper'

# Signed in, every account writes and sends in the inbox form (#93), so the
# classic form can't be used to send, whatever the client asks for.
RSpec.describe 'Submitting a request' do
  let(:user) { FactoryBot.create(:user, trusted: true) }
  let(:body) { FactoryBot.create(:public_body) }
  let(:submission) do
    { pro: '1', submitted_new_request: '1', preview: '0',
      info_request: { title: 'Depot inspection records',
                      public_body_id: body.id },
      outgoing_message: {
        body: "Dear authority,\n\nPlease send the depot inspection records." \
              "\n\nYours faithfully,\nA Requester"
      } }
  end

  context 'when signed in' do
    before do
      sign_in(user)
    end

    [:get, :head, :post].each do |verb|
      it "sends a #{verb.upcase} to the inbox form without sending anything" do
        expect {
          send(verb, '/new', params: submission)
        }.not_to(change {
          [InfoRequest.count, ActionMailer::Base.deliveries.size]
        })
        destination =
          if verb == :post
            new_alaveteli_pro_info_request_path(
              draft_id: user.draft_info_requests.last.id
            )
          else
            new_alaveteli_pro_info_request_path
          end
        expect(response).to redirect_to(destination)
      end
    end

    it 'does not trust a requester supplied in the URL' do
      get '/new', params: submission.merge(post_redirect_user: 'another user')
      expect(response).to redirect_to(new_alaveteli_pro_info_request_path)
    end
  end

  context 'when signed out' do
    [:get, :head].each do |verb|
      it "does not submit a request with #{verb.upcase}" do
        expect {
          send(verb, '/new', params: submission)
        }.not_to(change { [InfoRequest.count, PostRedirect.count] })
        expect(response).to have_http_status(:ok)
      end
    end

    it 'keeps the text of an explicit POST for after sign-in' do
      get '/new', params: submission
      expect(response.body).to include('Depot inspection records')
      expect {
        post '/new', params: submission
      }.not_to(change { InfoRequest.count })
      expect(JSON.parse(PendingRequestDraft.last.payload)['title']).
        to eq('Depot inspection records')
    end
  end
end
