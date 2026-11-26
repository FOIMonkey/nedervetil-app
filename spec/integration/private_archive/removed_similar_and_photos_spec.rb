require 'spec_helper'

RSpec.describe 'URLs of similar requests and profile photos' do
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Removedphototoken Owner') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:thread) {
    FactoryBot.create(:info_request, user: owner,
                                     title: 'Removedsimilartoken request')
  }

  def viewers
    { 'a visitor' => nil, 'the requester' => owner, 'an admin' => admin }
  end

  def visit_as(viewer, method, url)
    viewer ? sign_in(viewer) : reset!
    public_send(method, url)
  end

  def expect_not_found(method, url)
    viewers.each do |name, viewer|
      visit_as(viewer, method, url)
      expect(response).to have_http_status(:not_found),
                          "#{method.upcase} #{url} as #{name}"
      expect(response.body).not_to include('Removedsimilartoken')
      expect(response.headers['Location']).to be_nil
    end
  end

  it 'gives a 404 for the similar requests page and its old redirect' do
    expect_not_found(:get, "/request/#{thread.url_title}/similar")
    expect_not_found(:get, "/request/#{thread.url_title}/similar?page=2")
    expect_not_found(:get, "/similar/request/#{thread.url_title}")
  end

  it 'gives a 404 for the profile photo pages' do
    expect_not_found(:get, '/profile/set_photo')
    expect_not_found(:post, '/profile/set_photo')
    expect_not_found(:post, '/profile/clear_photo')
    expect_not_found(:post, "/admin/users/#{owner.id}/clear_profile_photo")
  end

  it 'answers the old photo images as any unknown .png URL' do
    ["/user/#{owner.url_name}/photo.png",
     '/profile/draft_photo/1.png'].each do |url|
      viewers.each do |name, viewer|
        visit_as(viewer, :get, '/no-such-page.png')
        expected = response.status
        visit_as(viewer, :get, url)
        expect(response.status).to eq(expected), "#{url} as #{name}"
        expect(response).not_to be_successful
        expect(response.headers['Location']).to be_nil
      end
    end
  end

  it 'shows the request page with no similar requests or photo' do
    sign_in(owner)
    get "/request/#{thread.url_title}"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('/similar')
    expect(response.body).not_to include('photo.png')
  end

  it 'shows the profile page with no photo link' do
    sign_in(owner)
    get "/user/#{owner.url_name}"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('set_photo')
    expect(response.body).not_to include('photo.png')
  end
end
