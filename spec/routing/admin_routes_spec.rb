require 'spec_helper'

# The admin URLs are bookmarked and appear in old mail, and their helper names
# are used by themes and add-ons, so they stay put whichever controller serves
# them. Written after moving the old top-level admin controllers under Admin::.
RSpec.describe 'Admin routes', type: :routing do
  # rubocop:disable Layout/LineLength
  {
    [:get, '/admin'] => 'admin/general#index',
    [:get, '/admin/jump'] => 'admin/jump#show',
    [:get, '/admin/timeline'] => 'admin/general#timeline',
    [:get, '/admin/stats'] => 'admin/general#stats',
    [:get, '/admin/spam_addresses'] => 'admin/spam_addresses#index',
    [:post, '/admin/spam_addresses'] => 'admin/spam_addresses#create',
    [:delete, '/admin/spam_addresses/1'] => 'admin/spam_addresses#destroy',
    [:get, '/admin/announcements/new'] => 'admin/announcements#new',
    [:put, '/admin/announcements/1'] => 'admin/announcements#update',
    [:get, '/admin/holidays/1/edit'] => 'admin/holidays#edit',
    [:get, '/admin/holiday_imports/new'] => 'admin/holiday_imports#new',
    [:post, '/admin/holiday_imports/preview'] => 'admin/holiday_imports#preview',
    [:get, '/admin/mail_server_logs/1/edit'] => 'admin/mail_server_logs#edit',
    [:get, '/admin/bodies'] => 'admin/public_bodies#index',
    [:get, '/admin/bodies/import_csv'] => 'admin/public_bodies#import_csv',
    [:post, '/admin/bodies/import_csv'] => 'admin/public_bodies#import_csv',
    [:delete, '/admin/bodies/1'] => 'admin/public_bodies#destroy',
    [:get, '/admin/change_requests/1/edit'] => 'admin/public_body_change_requests#edit',
    [:get, '/admin/requests'] => 'admin/requests#index',
    [:post, '/admin/requests/1/move'] => 'admin/requests#move',
    [:patch, '/admin/requests/1/prominence'] => 'admin/requests#prominence',
    [:get, '/admin/raw_emails/1'] => 'admin/raw_emails#show',
    [:get, '/admin/info_request_events/1/edit'] => 'admin/info_request_events#edit',
    [:get, '/admin/incoming_messages/1/edit'] => 'admin/incoming_messages#edit',
    [:post, '/admin/incoming_messages/bulk_destroy'] => 'admin/incoming_messages#bulk_destroy',
    [:get, '/admin/outgoing_messages'] => 'admin/outgoing_messages#index',
    [:post, '/admin/outgoing_messages/1/resend'] => 'admin/outgoing_messages#resend',
    [:get, '/admin/users'] => 'admin/users#index',
    [:get, '/admin/users/banned'] => 'admin/users#banned',
    [:get, '/admin/users/1/show_bounce_message'] => 'admin/users#show_bounce_message',
    [:delete, '/admin/users/1/slugs/2'] => 'admin/users/slugs#destroy'
  }.each do |(verb, path), target|
    it "sends #{verb.upcase} #{path} to #{target}" do
      controller, action = target.split('#')
      expect(verb => path).to route_to(
        { controller: controller, action: action }.merge(params_in(path))
      )
    end
  end
  # rubocop:enable Layout/LineLength

  def params_in(path)
    case path
    when %r{/users/1/slugs/2\z} then { user_id: '1', id: '2' }
    when %r{/(\d+)(/|\z)} then { id: Regexp.last_match(1) }
    else {}
    end
  end

  # rubocop:disable Layout/LineLength
  it 'keeps the helper names themes and add-ons use' do
    helpers = Rails.application.routes.url_helpers
    expect(helpers.admin_general_index_path).to eq('/admin')
    expect(helpers.admin_timeline_path).to eq('/admin/timeline')
    expect(helpers.admin_stats_path).to eq('/admin/stats')
    expect(helpers.admin_body_path(1)).to eq('/admin/bodies/1')
    expect(helpers.import_csv_admin_bodies_path).to eq('/admin/bodies/import_csv')
    expect(helpers.admin_request_path(1)).to eq('/admin/requests/1')
    expect(helpers.admin_user_path(1)).to eq('/admin/users/1')
    expect(helpers.admin_user_slug_path(user_id: 1, id: 2)).to eq('/admin/users/1/slugs/2')
    expect(helpers).not_to respond_to(:admin_users_sessions_path)
    expect(helpers.edit_admin_outgoing_message_path(1)).to eq('/admin/outgoing_messages/1/edit')
    expect(helpers.edit_admin_incoming_message_path(1)).to eq('/admin/incoming_messages/1/edit')
    expect(helpers.bulk_destroy_admin_incoming_messages_path).to eq('/admin/incoming_messages/bulk_destroy')
    expect(helpers.admin_change_requests_path).to eq('/admin/change_requests')
    expect(helpers.admin_mail_server_logs_path).to eq('/admin/mail_server_logs')
    expect(helpers.admin_raw_email_path(1, format: 'eml')).to eq('/admin/raw_emails/1.eml')
  end
  # rubocop:enable Layout/LineLength

  it 'keeps the links made from a record' do
    helpers = Rails.application.routes.url_helpers
    expect(helpers.admin_public_body_path(1)).to eq('/admin/bodies/1')
    expect(helpers.admin_info_request_path(1)).to eq('/admin/requests/1')
  end

  it 'has no route left pointing at a top-level admin controller' do
    targets = Rails.application.routes.routes.map do |route|
      route.defaults[:controller].to_s
    end
    expect(targets.grep(/\Aadmin_/)).to eq([])
  end
end
