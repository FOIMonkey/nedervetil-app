require 'spec_helper'

RSpec.describe 'user/_signup' do
  it 'lets Tab follow the page and password managers fill the form' do
    # A view spec's controller is not an ApplicationController, so the view
    # lacks the helpers that one declares.
    view.singleton_class.include(ApplicationController._helpers)
    allow(view).to receive(:sign_page_params).and_return({})
    render partial: 'user/signup'
    form = Nokogiri::HTML(rendered)
    expect(form.css('[tabindex]')).to be_empty
    {
      '#user_signup_name' => 'name',
      '#user_signup_email' => 'email'
    }.each do |field, hint|
      expect(form.at_css(field)['autocomplete']).to eq(hint), field
    end
    # The confirmation link asks for the password.
    expect(form.css('input[type="password"]')).to be_empty
  end
end
