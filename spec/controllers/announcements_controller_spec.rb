require 'spec_helper'

RSpec.describe AnnouncementsController do
  describe '#destroy' do
    context 'valid announcement' do
      let(:announcement) { FactoryBot.create(:announcement) }

      context 'logged in' do
        let(:user) { FactoryBot.create(:user) }
        before { sign_in user }

        it 'creates dismissal' do
          expect {
            delete :destroy, params: { id: announcement.id }
          }.to change(AnnouncementDismissal, :count).by(1)
        end

        it 'redirects back to the page the dismissal came from' do
          request.env['HTTP_REFERER'] = 'http://test.host/help/about'
          delete :destroy, params: { id: announcement.id }
          expect(response).to redirect_to('http://test.host/help/about')
        end

        it 'returns 200 status for a remote dismissal' do
          delete :destroy, params: { id: announcement.id }, xhr: true
          expect(response.status).to eq 200
        end
      end

      context 'logged out' do
        it 'stores announcement ID in session' do
          expect(session[:announcement_dismissals]).to be_nil
          delete :destroy, params: { id: announcement.id }
          expect(session[:announcement_dismissals]).
            to match_array([announcement.id])
        end

        it 'redirects to the front page when there is nowhere to go back to' do
          delete :destroy, params: { id: announcement.id }
          expect(response).to redirect_to(frontpage_path)
        end
      end
    end

    context 'invalid announcement' do
      it 'returns 403 status' do
        delete :destroy, params: { id: 'invalid' }
        expect(response.status).to eq 403
      end
    end
  end
end
