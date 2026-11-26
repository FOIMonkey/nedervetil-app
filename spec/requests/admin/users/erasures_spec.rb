require 'spec_helper'

RSpec.describe 'Admin user erasures', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }
  let(:user) { FactoryBot.create(:user) }

  before { sign_in admin_user }

  describe 'POST create' do
    def erase
      post admin_user_erasure_path(user), params: { reason: 'GDPR' }
    end

    context 'with valid params for erasing' do
      before { user.close }

      it 'enqueues a User::ErasureJob for the user' do
        expect { erase }.
          to have_enqueued_job(User::ErasureJob).
          with(user, editor: admin_user.url_name, reason: 'GDPR')
      end

      it 'redirects to the user page' do
        erase
        expect(response).to redirect_to(admin_user_path(user))
      end

      it 'tells the admin that the erasure will be processed' do
        erase
        expect(flash[:notice]).to eq('User erasure queued.')
      end
    end

    context 'when an account is not closed' do
      it 'does not enqueue a User::ErasureJob' do
        expect { erase }.not_to have_enqueued_job(User::ErasureJob)
        expect(response).to redirect_to(admin_user_path(user))
      end

      it 'redirects to the user page' do
        erase
        expect(response).to redirect_to(admin_user_path(user))
      end

      it 'tells the admin that the user cannot be erased' do
        erase
        expect(flash[:error]).
          to eq('Only a closed account that is not banned can be erased.')
      end
    end

    # The button is disabled for a banned account; this is the rule itself.
    context 'when a closed account is banned' do
      before do
        user.update!(ban_text: 'Spam')
        user.close
      end

      it 'refuses to erase it' do
        expect { erase }.not_to have_enqueued_job(User::ErasureJob)
        expect(response).to redirect_to(admin_user_path(user))
        expect(flash[:error]).
          to eq('Only a closed account that is not banned can be erased.')
      end
    end

    context 'with invalid params' do
      it 'renders a 404' do
        get admin_user_path(user)
        expect(response).to have_http_status(:ok)

        post admin_user_erasure_path(user_id: 0)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
