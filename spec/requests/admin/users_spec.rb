require 'spec_helper'

RSpec.describe 'Admin users', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }
  let(:page) { Nokogiri::HTML(response.body) }

  describe 'GET index' do
    before { sign_in admin_user }

    def listed
      ids = page.css('#users .item-detail-body[id^="user_"]').
        map { |row| row['id'].delete_prefix('user_').to_i }
      users = User.where(id: ids).index_by(&:id)
      ids.map { |id| users.fetch(id) }
    end

    def chosen_sort_order
      page.at_css('input[type=hidden][name=sort_order]')['value']
    end

    def offered_sort_orders
      page.css('.sort-options a').map do |link|
        next chosen_sort_order if link['href'] == '#'

        Rack::Utils.parse_query(URI(link['href']).query)['sort_order']
      end
    end

    it 'shows the users page' do
      get admin_users_path
      expect(response).to have_http_status(:ok)
      expect(page.css('h1').map { |h| h.text.strip }).
        to include('Listing users')
      expect(listed).to include(admin_user)
    end

    it 'keeps the title and navbar in the admin layout' do
      get admin_users_path

      expect(page.at_css('title').text).to include('Listing users', 'admin')
      expect(page.at_css('body.admin #admin-bar')).to be_present
    end

    it 'sets a default sort order' do
      get admin_users_path
      expect(chosen_sort_order).to eq('name_asc')
      expect(page.at_css('.sort-options a.disabled').text).to eq('Name ▲')
    end

    it 'offers the sort options' do
      get admin_users_path
      expect(offered_sort_orders).to eq(%w[name_asc name_desc
                                           created_at_asc created_at_desc
                                           updated_at_asc updated_at_desc])
    end

    it 'uses a custom sort order if valid' do
      get admin_users_path, params: { sort_order: 'created_at_asc' }
      expect(chosen_sort_order).to eq('created_at_asc')
      expect(page.at_css('.sort-options a.disabled').text).to eq('Oldest')
    end

    it 'uses the default sort order if a custom sort order is invalid' do
      get admin_users_path, params: { sort_order: 'invalid' }
      expect(chosen_sort_order).to eq('name_asc')
    end

    it 'sorts the records by name_asc' do
      u1 = FactoryBot.create(:user, name: 'Bob')
      u2 = FactoryBot.create(:user, name: 'Alice')
      get admin_users_path, params: { sort_order: 'name_asc' }
      expect(listed & [u1, u2]).to eq([u2, u1])
    end

    it 'sorts the records by name_desc' do
      u1 = FactoryBot.create(:user, name: 'Alice')
      u2 = FactoryBot.create(:user, name: 'Bob')
      get admin_users_path, params: { sort_order: 'name_desc' }
      expect(listed & [u1, u2]).to eq([u2, u1])
    end

    it 'sorts the records by created_at_asc' do
      u1 = FactoryBot.create(:user, name: 'Bob')
      u2 = FactoryBot.create(:user, name: 'Alice')
      get admin_users_path, params: { sort_order: 'created_at_asc' }
      expect(listed & [u1, u2]).to eq([u1, u2])
    end

    it 'sorts the records by created_at_desc' do
      u1 = FactoryBot.create(:user, name: 'Alice')
      u2 = FactoryBot.create(:user, name: 'Bob')
      get admin_users_path, params: { sort_order: 'created_at_desc' }
      expect(listed & [u1, u2]).to eq([u2, u1])
    end

    it 'sorts the records by updated_at_asc' do
      u1 = FactoryBot.create(:user, name: 'Alice')
      u2 = FactoryBot.create(:user, name: 'Bob')
      u1.touch
      get admin_users_path, params: { sort_order: 'updated_at_asc' }
      expect(listed & [u1, u2]).to eq([u2, u1])
    end

    it 'sorts the records by updated_at_desc' do
      u1 = FactoryBot.create(:user, name: 'Bob')
      u2 = FactoryBot.create(:user, name: 'Alice')
      u1.touch
      get admin_users_path, params: { sort_order: 'updated_at_desc' }
      expect(listed & [u1, u2]).to eq([u1, u2])
    end

    it 'lists users matching a case-insensitive query' do
      user = FactoryBot.create(:user, name: 'Bob Smith')
      get admin_users_path, params: { query: 'bob' }
      expect(listed).to include(user)
    end

    it 'strips the string when searching' do
      user = FactoryBot.create(:user, email: 'julie@example.com')
      get admin_users_path, params: { query: ' julie@example.com ' }
      expect(listed).to include(user)
    end

    it 'finds users by a partial email fragment' do
      user = FactoryBot.create(:user, email: 'julie@example.com')
      get admin_users_path, params: { query: '@example.com' }
      expect(listed).to include(user)
    end

    it 'searches and sorts the records' do
      u1 = FactoryBot.create(:user, name: 'Alice Quillfeather')
      u2 = FactoryBot.create(:user, name: 'Bob Quillfeather')
      FactoryBot.create(:user, name: 'John Doe')
      get admin_users_path,
          params: { query: 'quillfeather', sort_order: 'name_desc' }
      expect(listed).to eq([u2, u1])
    end

    it 'sorts by relevance until another order is chosen' do
      alice = FactoryBot.create(:user, name: 'Alice Quillfeather')
      bob = FactoryBot.create(
        :user, name: 'Bob Quillfeather Quillfeather Quillfeather'
      )
      get admin_users_path, params: { query: 'quillfeather' }
      expect(listed).to eq([bob, alice])
    end

    it 'sorts by the chosen column rather than search relevance' do
      alice = FactoryBot.create(:user, name: 'Alice Quillfeather')
      bob = FactoryBot.create(
        :user, name: 'Bob Quillfeather Quillfeather Quillfeather'
      )
      get admin_users_path,
          params: { query: 'quillfeather', sort_order: 'name_asc' }
      expect(listed).to eq([alice, bob])
    end

    it 'filters the records by role' do
      other_admin = FactoryBot.create(:admin_user)
      user = FactoryBot.create(:user)
      get admin_users_path, params: { roles: ['admin'] }
      expect(listed).to include(admin_user, other_admin)
      expect(listed).not_to include(user)
      expect(listed).to all(be_is_admin)
    end

    context 'filtering by role and search query' do
      let!(:alice) { FactoryBot.create(:admin_user, name: 'Alice Smith') }
      let!(:carol) do
        FactoryBot.create(:admin_user, name: 'Carol Smith Smith Smith')
      end

      before do
        User.where.not(id: [alice.id, carol.id, admin_user.id]).destroy_all
        FactoryBot.create(:user, name: 'Bob Smith')
        FactoryBot.create(:admin_user, name: 'Dave Jones')
      end

      it 'keeps search relevance order' do
        get admin_users_path, params: { roles: ['admin'], query: 'smith' }
        expect(listed).to eq([carol, alice])
      end

      it 'sorts by the chosen column' do
        get admin_users_path, params: { roles: ['admin'], query: 'smith',
                                        sort_order: 'name_asc' }
        expect(listed).to eq([alice, carol])
      end

      it 'filters with the legacy search too' do
        get admin_users_path, params: { roles: ['admin'], query: 'smith',
                                        search_engine: 'legacy',
                                        sort_order: 'name_asc' }
        expect(listed).to eq([alice, carol])
      end
    end
  end

  describe 'GET show' do
    let(:info_request) { FactoryBot.create(:info_request) }

    before { sign_in admin_user }

    it 'is successful' do
      user = FactoryBot.create(:user)
      get admin_user_path(user)
      expect(response).to have_http_status(:ok)
      expect(page.css('h1').map { |h| h.text.strip }).
        to include("User – #{user.name}")
    end

    it "lists the user's info requests" do
      get admin_user_path(info_request.user)
      listed = page.css('#requests .item-title a').
        map { |link| link['href'] }.grep(%r{\A/admin/requests/})
      expect(listed).to eq([admin_request_path(info_request)])
    end

    it 'renders ERB syntax in user fields literally without evaluating it' do
      user = FactoryBot.create(:user, name: 'Alice <%= 1 + 1 %>')
      get admin_user_path(user)
      expect(response).to have_http_status(:ok)
      expect(page.css('h1').map { |h| h.text.strip }).
        to include('User – Alice <%= 1 + 1 %>')
      expect(page.at_css('title').text).to include('Alice <%= 1 + 1 %>')
    end
  end

  # The form sends no role_ids at all when no role is ticked.
  describe 'PUT update' do
    let(:other_admin) { FactoryBot.create(:admin_user) }

    it "saves a change to 'trusted'" do
      user = FactoryBot.create(:user)
      expect(user.trusted?).to be false
      sign_in admin_user
      put admin_user_path(user), params: {
        admin_user: {
          name: user.name,
          email: user.email,
          ban_text: user.ban_text,
          role_ids: user.role_ids.presence,
          trusted: '1',
          confirmed_not_spam: user.confirmed_not_spam
        }
      }
      expect(flash[:notice]).to eq('User successfully updated.')
      expect(response).to redirect_to(admin_user_url(user))
      follow_redirect!
      expect(page.at_css('body.admin .alert-info').text).
        to include('User successfully updated.')
      user = User.find(user.id)
      expect(user.trusted?).to be true
      expect(user.permission_changes.pluck(:what, :granted, :changed_by_id)).
        to eq([['trusted', true, admin_user.id]])
    end

    it 'should not allow an existing email address to be used' do
      existing_email = 'donotreuse@localhost'
      FactoryBot.create(:user, email: existing_email)
      user = FactoryBot.create(:user, email: 'user1@localhost')
      sign_in admin_user
      put admin_user_path(user), params: {
        admin_user: {
          name: user.name,
          email: existing_email,
          ban_text: user.ban_text,
          role_ids: user.role_ids.presence,
          trusted: user.trusted,
          confirmed_not_spam: user.confirmed_not_spam
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:error]).to be_nil
      expect(page.at_css('#errorExplanation')).to be_present
      user = User.find(user.id)
      expect(user.email).to eq('user1@localhost')
    end

    it "sets the user's roles" do
      user = FactoryBot.create(:user)
      admin_role = Role.where(name: 'admin').first
      expect(user.is_admin?).to be false
      sign_in admin_user
      put admin_user_path(user), params: {
        admin_user: {
          name: user.name,
          ban_text: user.ban_text,
          role_ids: user.role_ids + [admin_role.id],
          trusted: user.trusted,
          confirmed_not_spam: user.confirmed_not_spam
        }
      }
      user = User.find(user.id)
      expect(user.is_admin?).to be true
      expect(user.permission_changes.pluck(:what, :granted, :changed_by_id)).
        to eq([['admin', true, admin_user.id]])
    end

    it "unsets the user's roles if no role ids are supplied" do
      expect(other_admin.is_admin?).to be true
      sign_in other_admin
      put admin_user_path(other_admin), params: {
        admin_user: {
          name: other_admin.name,
          ban_text: other_admin.ban_text,
          trusted: other_admin.trusted,
          confirmed_not_spam: other_admin.confirmed_not_spam
        }
      }
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).
        to eq('User successfully updated - you are no longer an admin.')
      user = User.find(other_admin.id)
      expect(user.is_admin?).to be false
      expect(user.permission_changes.pluck(:what, :granted, :changed_by_id)).
        to eq([['admin', false, other_admin.id]])
    end

    it 'records nothing when neither the Trusted tick nor the admin role ' \
       'changes' do
      user = FactoryBot.create(:user)
      sign_in admin_user
      put admin_user_path(user), params: {
        admin_user: {
          name: 'A new name',
          ban_text: user.ban_text,
          role_ids: user.role_ids.presence,
          trusted: user.trusted,
          confirmed_not_spam: user.confirmed_not_spam
        }
      }
      expect(user.reload.name).to eq('A new name')
      expect(user.permission_changes).to be_empty
    end

    context 'when the save fails' do
      let(:taken_email) { FactoryBot.create(:user).email }

      def update_with_taken_email(user, **changes)
        put admin_user_path(user), params: {
          admin_user: {
            name: user.name,
            email: taken_email,
            ban_text: user.ban_text,
            role_ids: user.role_ids,
            trusted: user.trusted,
            confirmed_not_spam: user.confirmed_not_spam
          }.merge(changes)
        }
      end

      it 'does not grant the admin role' do
        user = FactoryBot.create(:user)
        sign_in admin_user
        update_with_taken_email(user, role_ids: [Role.admin_role.id])
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('#admin_user_email')['value']).to eq(taken_email)
        admin_box = page.at_css('input[name="admin_user[role_ids][]"]' \
                                "[value=\"#{Role.admin_role.id}\"]")
        expect(admin_box['checked']).to be_present
        user = User.find(user.id)
        expect(user.is_admin?).to be false
        expect(user.permission_changes).to be_empty
      end

      it 'does not remove the admin role' do
        sign_in admin_user
        update_with_taken_email(other_admin, role_ids: [])
        expect(response).to have_http_status(:unprocessable_content)
        user = User.find(other_admin.id)
        expect(user.is_admin?).to be true
        expect(user.permission_changes).to be_empty
      end

      it 'keeps the tags' do
        user = FactoryBot.create(:user)
        user.tag_string = 'kept'
        sign_in admin_user
        update_with_taken_email(user, tag_string: 'replaced')
        expect(response).to have_http_status(:unprocessable_content)
        expect(User.find(user.id).tag_string).to eq('kept')
      end

      it 'does not switch on a feature' do
        user = FactoryBot.create(:user)
        sign_in admin_user
        update_with_taken_email(user, features: ['pro_batch_category_add_all'])
        expect(response).to have_http_status(:unprocessable_content)
        expect(User.find(user.id).features.
          enabled?(:pro_batch_category_add_all)).to be false
      end
    end

    context 'on the user page' do
      it 'shows who changed the Trusted tick' do
        user = FactoryBot.create(:user)
        user.permission_changes.create!(what: 'trusted', granted: true,
                                        changed_by: admin_user)
        sign_in admin_user
        get admin_user_path(user)
        expect(response.body).to include('Permission history', 'Trusted',
                                         'given', admin_user.name)
      end
    end

    it 'does not set a role that does not exist' do
      user = FactoryBot.create(:user)
      role_id = Role.maximum(:id) + 1
      expect(user.roles).to be_empty
      sign_in admin_user
      put admin_user_path(user), params: {
        admin_user: {
          name: user.name,
          ban_text: user.ban_text,
          role_ids: user.role_ids + [role_id],
          trusted: user.trusted,
          confirmed_not_spam: user.confirmed_not_spam
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:error]).to eq('Not permitted to change roles')
      user = User.find(user.id)
      expect(user.roles).to be_empty
    end
  end
end
