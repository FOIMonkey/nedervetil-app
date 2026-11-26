require 'spec_helper'

# What signing in and signing out do to the session a browser holds.
RSpec.describe 'The session at sign-in and sign-out', type: :request do
  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:origin) { { 'Origin' => "http://#{host}" } }

  it 'is a new one after signing out' do
    sign_in(owner)
    # The page after a sign-in has the session that lasts.
    get alaveteli_pro_dashboard_path
    signed_in = session[:session_id]
    expect(signed_in).to be_present

    delete signout_path, headers: origin

    expect(session[:session_id]).not_to eq(signed_in)
  end

  it 'keeps nothing a visitor’s session held, once they sign in' do
    announcement = FactoryBot.create(:announcement)
    delete announcement_path(announcement), headers: origin
    expect(session[:announcement_dismissals]).to eq([announcement.id])

    sign_in(owner)

    expect(session[:announcement_dismissals]).to be_nil
  end
end
