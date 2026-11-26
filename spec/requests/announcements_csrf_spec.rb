require 'spec_helper'

RSpec.describe 'Announcement dismissal CSRF', type: :request do
  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  it 'rejects a signed-in dismissal without an authenticity token' do
    user = FactoryBot.create(:user)
    announcement = FactoryBot.create(:announcement)
    post signin_path,
         params: { user_signin: { email: user.email,
                                  password: 'jonespassword' } }
    expect(request.env['warden'].user(scope: :user)).to eq(user)

    ActionController::Base.allow_forgery_protection = true
    delete announcement_path(announcement)

    expect(response).to have_http_status(422)
    expect(AnnouncementDismissal.where(announcement: announcement,
                                       user: user)).not_to exist
  end
end
