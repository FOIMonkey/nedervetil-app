require 'spec_helper'

RSpec.describe 'user/_signin' do
  before do
    assign :user_signin, User.new
    # A view spec's controller is not an ApplicationController, so the view
    # lacks the helpers that one declares.
    view.singleton_class.include(ApplicationController._helpers)
    allow(view).to receive(:sign_page_params).and_return({})
  end

  def render_form
    render partial: 'user/signin'
  end

  it 'offers password and second factor without emergency or remember-me bypasses' do
    allow(AlaveteliConfiguration).
      to receive(:disable_emergency_user).and_return(false)
    render_form
    expect(rendered).to include('id="signin_form"', 'user_signin[password]',
      'user_signin[otp_attempt]')
    expect(rendered).not_to include('emergency=1', 'remember_me',
      'post_redirect')
  end

  it 'lets Tab follow the page and password managers fill the form' do
    render_form
    form = Nokogiri::HTML(rendered)
    expect(form.css('[tabindex]')).to be_empty
    {
      '#user_signin_email' => 'username',
      '#user_signin_password' => 'current-password',
      '#user_signin_otp_attempt' => 'one-time-code'
    }.each do |field, hint|
      expect(form.at_css(field)['autocomplete']).to eq(hint), field
    end
  end

  it 'escapes a supplied email and never repopulates credentials' do
    assign :user_signin,
      User.new(email: '<script>invented</script>',
               password: 'invented-password')
    render_form
    expect(rendered).not_to include('<script>invented</script>',
      'invented-password')
  end
end
