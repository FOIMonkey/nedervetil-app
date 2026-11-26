require 'spec_helper'

RSpec.describe 'Private archive access and unified inbox', type: :request do
  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:other) { FactoryBot.create(:user, name: 'Other Account') }
  let(:admin) { FactoryBot.create(:admin_user, :enable_totp) }
  let(:suspended_admin) do
    FactoryBot.create(:admin_user, :enable_totp, ban_text: 'Suspended')
  end
  let(:thread) do
    FactoryBot.create(:info_request, user: owner,
                                     title: 'Secretthreadtoken private letter')
  end
  let(:batch) do
    FactoryBot.create(:info_request_batch, user: owner,
                                           title: 'Secretbatchtoken batch')
  end

  def with_production_error_pages
    env_config = Rails.application.env_config
    orig_show = env_config['action_dispatch.show_exceptions']
    orig_detailed = env_config['action_dispatch.show_detailed_exceptions']
    orig_local = Rails.application.config.consider_all_requests_local
    env_config['action_dispatch.show_exceptions'] = :all
    env_config['action_dispatch.show_detailed_exceptions'] = false
    Rails.application.config.consider_all_requests_local = false
    yield
  ensure
    env_config['action_dispatch.show_exceptions'] = orig_show
    env_config['action_dispatch.show_detailed_exceptions'] = orig_detailed
    Rails.application.config.consider_all_requests_local = orig_local
  end

  describe 'request, batch, and account privacy' do
    it 'denies requests, batches, events, and retired feeds to visitors and other users' do
      with_production_error_pages do
        event = thread.info_request_events.first
        urls = [
          request_path(thread),
          request_path(thread, format: :json),
          "/request/#{thread.url_title}/details",
          "/request/#{thread.url_title}/download",
          "/request/#{thread.url_title}/feed",
          "/request/#{thread.url_title}/track",
          "/request_event/#{event.id}",
          "/r/fake-public-token",
          info_request_batch_path(batch),
          "/user/#{owner.url_name}",
          "/user/#{owner.url_name}.json",
          "/user/#{owner.url_name}/wall",
          "/feed/user/#{owner.url_name}",
          "/user/contact/#{owner.url_name}"
        ]

        [nil, other].each do |viewer|
          viewer ? sign_in(viewer) : reset!
          urls.each do |url|
            get url
            expect(response.status).to eq(404), "#{viewer&.name || 'guest'} -> #{url}"
            expect(response.body).not_to include('Secretthreadtoken', 'Secretbatchtoken', owner.name)
            expect(response.headers['Cache-Control']).to include('no-store')
          end
        end
      end
    end

    it 'does not authorize a request via a second readable title parameter' do
      with_production_error_pages do
        readable = FactoryBot.create(:info_request, user: other)
        sign_in(other)

        get "/request/#{thread.url_title}",
            params: { request_url_title: readable.url_title }
        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include('Secretthreadtoken')

        event = FactoryBot.create(:edit_event, info_request: thread)
        get "/request_event/#{event.id}",
            params: { url_title: readable.url_title }
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'allows the requester to read their own request, but hides hidden requests from them' do
      sign_in(owner)
      get request_path(thread)
      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to include('no-store')

      thread.update!(prominence: 'hidden')
      with_production_error_pages do
        get request_path(thread)
        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include('Secretthreadtoken')
      end
    end

    it 'allows an active admin to read hidden requests, while stripping suspended admins of powers' do
      thread.update!(prominence: 'hidden')
      expect(Ability.new(admin).can?(:read, thread)).to be(true)
      expect(Ability.new(admin).can?(:access, :admin)).to be(true)
      expect(Ability.new(suspended_admin).can?(:read, thread)).to be(false)
      expect(Ability.new(suspended_admin).can?(:access, :admin)).to be(false)
    end

    it 'denies direct Active Storage signed blob URLs with 404 and no-store' do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new('private file bytes'),
        filename: 'private.txt',
        content_type: 'text/plain'
      )
      get rails_blob_path(blob, only_path: true)
      expect(response).to have_http_status(:not_found)
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(response.body).not_to include('private file bytes')
    end

    it 'keeps private statistics out of /version.json' do
      get '/version.json'
      expect(response).to have_http_status(:ok)
      keys = JSON.parse(response.body).keys
      expect(keys).to match_array(%w[alaveteli_git_commit alaveteli_version ruby_version])
    end
  end

  describe 'unified inbox without Pro roles or billing' do
    it 'allows any ordinary signed-in account to access /pro/info_requests' do
      sign_in(owner)
      get alaveteli_pro_info_requests_path
      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to include('no-store')
    end

    it 'prompts signed-out visitors to sign in before entering the inbox' do
      get alaveteli_pro_info_requests_path
      expect(response).to have_http_status(:found)
      expect(response.headers['Location']).to include('/profile/sign_in')
    end

    it 'grants batch creation only to trusted accounts and active admins' do
      trusted = FactoryBot.create(:user, :trusted)
      expect(Ability.new(owner).can?(:create, InfoRequestBatch)).to be(false)
      expect(Ability.new(trusted).can?(:create, InfoRequestBatch)).to be(true)
      expect(Ability.new(admin).can?(:create, InfoRequestBatch)).to be(true)
      expect(Ability.new(suspended_admin).can?(:create, InfoRequestBatch)).to be(false)
    end

    it 'allows only the admin role' do
      expect(Role.allowed_roles).to eq(%w[admin])
      expect(Role.new(name: 'pro')).not_to be_valid
      expect(Role.new(name: 'pro_admin')).not_to be_valid
    end
  end
end
