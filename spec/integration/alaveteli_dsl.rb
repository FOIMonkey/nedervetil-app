module AlaveteliDsl
  def browse_request(url_title)
    visit "/request/#{url_title}"
  end

  def browse_pro_request(url_title)
    browse_request(url_title)
  end

  # Visit and fill out the pro-specific new request form
  # Note: you'll need to be logged in as a pro user to access this page.
  def create_pro_request(public_body)
    visit new_alaveteli_pro_info_request_path
    expect(page).to have_content "Make a request"

    fill_in "To", with: public_body.name
    click_button "Search"

    within ".body_listing" do
      find_link('Make a request').click
    end

    fill_in "Subject", with: "Does the pro request form work?"
    fill_in "Your request", with: "A very short letter."
    select "3 Months", from: "Privacy"
  end

  def add_body_to_pro_batch(public_body)
    within(
      ".batch-builder__search-results li[data-body-id=\"#{public_body.id}\"]"
    ) do
      click_button "Add"
    end
  end
end

def hide_incoming_message(incoming_message, prominence, reason)
  visit edit_admin_incoming_message_path(incoming_message)
  select prominence, from: 'Prominence'
  fill_in 'Reason for prominence', with: reason
  find_button('Save').click
end

def hide_outgoing_message(outgoing_message, prominence, reason)
  visit edit_admin_outgoing_message_path(outgoing_message)
  select prominence, from: 'Prominence'
  fill_in 'Reason for prominence', with: reason
  find_button('Save').click
end

def classify_request(request, chosen_option)
  visit show_request_path(request.url_title, update_status: 1)
  choose(chosen_option)
  click_button('Submit status')
end

def alaveteli_session(session_id)
  using_session session_id do
    extend AlaveteliDsl
    yield
  end
end

def using_pro_session(session_id)
  with_feature_enabled(:alaveteli_pro) do
    using_session(session_id) do
      yield
    end
  end
end

def login(user, **params)
  u = user.is_a?(User) ? user : users(user)
  if u.is_admin? && !u.totp?
    u.update!(otp_secret: User.generate_otp_secret,
              otp_required_for_login: true)
  end
  code = nil
  if u.totp?
    # Arrange a fresh fixture proof; replay is tested by dedicated flows.
    u.update_columns(consumed_timestep: nil)
    code = u.current_otp
  end
  alaveteli_session(u.id) do
    visit signin_path(**params)
    within '#signin_form' do
      fill_in "user_signin_email", with: u.email
      fill_in "user_signin_password", with: "jonespassword"
      fill_in 'user_signin_otp_attempt', with: code if code
      click_button(name: 'commit', visible: :visible)
    end
  end
  u.id
end

def without_login
  session_id = "without_login"
  using_session session_id do
    extend AlaveteliDsl
  end
  session_id
end

def confirm(user)
  u = users(user)
  u.skip_confirmation!
  u.save!
end

def close_request(request)
  request.allow_new_responses_from = 'nobody'
  request.handle_rejected_responses = 'holding_pen'
  request.save!
end

def holding_pen_messages
  InfoRequest.holding_pen_request.incoming_messages
end

def last_holding_pen_mail
  InfoRequest.holding_pen_request.last_public_response.raw_email
end

def confirmation_url_from_email
  deliveries = ActionMailer::Base.deliveries
  expect(deliveries.size).to eq(1)
  mail = deliveries.first
  mail.body.to_s[/(http:\/\/.*\/c\/.*)/, 1]
end

def cache_directories_exist?(request)
  cache_path = File.join(Rails.root, 'cache', 'views')
  paths = [File.join(cache_path, 'request', request.request_dirs)]
  AlaveteliLocalization.available_locales.each do |locale|
    paths << File.join(cache_path, locale, 'request', request.request_dirs)
  end
  paths.any? { |path| File.exist?(path) }
end

def with_forgery_protection
  orig = ActionController::Base.allow_forgery_protection
  begin
    ActionController::Base.allow_forgery_protection = true
    yield if block_given?
  ensure
    ActionController::Base.allow_forgery_protection = orig
  end
end
