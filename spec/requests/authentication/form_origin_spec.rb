require 'spec_helper'

RSpec.describe 'Where a signed-out form was sent from', type: :request do
  let(:owner) { FactoryBot.create(:user) }

  around do |example|
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  def signed_in_from(origin)
    post signin_path,
         params: { user_signin: { email: owner.email,
                                  password: 'jonespassword' } },
         headers: { 'Origin' => origin }
    request.env['warden'].user(scope: :user)
  end

  it 'is taken from this site' do
    expect(signed_in_from("http://#{host}")).to eq(owner)
  end

  it 'is refused from this host under another scheme' do
    expect(signed_in_from("https://#{host}")).to be_nil
    expect(response).to have_http_status(422)
  end

  it 'is refused from this host on another port' do
    expect(signed_in_from("http://#{host}:8080")).to be_nil
    expect(response).to have_http_status(422)
  end

  # Various URI.parse errors and non-HTTP schemes must all return 422.
  ['mailto:x', 'http://[bad', 'null', 'ftp://www.example.com'].each do |origin|
    it "is refused from #{origin}, which is not a web address of this site" do
      expect(signed_in_from(origin)).to be_nil
      expect(response).to have_http_status(422)
      expect(response.body).to include("This form couldn't be sent")
    end
  end
end
