require 'spec_helper'

RSpec.describe 'Cookies' do
  include_context 'with production error pages'

  it 'sends a visitor none' do
    get '/'
    expect(response.headers['Set-Cookie']).to be_blank

    get '/help/about'
    expect(response.headers['Set-Cookie']).to be_blank
  end

  it 'shows a visitor a flash once, then forgets the cookie that carried it' do
    post '/help/contact', params: {
      contact: { name: 'Vinny Vanilli', email: 'vinny@localhost',
                 subject: 'Why do I have such an ace name?', comment: '',
                 message: "You really should know!!!\n\nVinny" },
      submitted_contact_form: 1
    }
    expect(response).to redirect_to(frontpage_path)
    expect(response.headers['Set-Cookie']).to include('_nedervetil_session=')

    follow_redirect!
    expect(response.body).to include('Your message has been sent')
    expect(response.headers['Set-Cookie']).
      to match(/_nedervetil_session=;.*max-age=0/m)

    get '/help/about'
    expect(response.body).not_to include('Your message has been sent')
    expect(response.headers['Set-Cookie']).to be_blank
  end

  it 'sends a signed-in account no language cookie' do
    sign_in(FactoryBot.create(:user))
    get '/'
    expect(response.headers['Set-Cookie'].to_s).not_to match(/\blocale=/)
  end

  it 'notes the language on the account only when it changes' do
    user = FactoryBot.create(:user)
    user.update_column(:locale, nil)
    sign_in(user)
    writes = 0
    counter = ->(*, payload) do
      writes += 1 if payload[:sql].start_with?('UPDATE "users" SET "locale"')
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      get '/help/about'
      get '/help/about'
    end

    expect(user.reload.read_attribute(:locale)).
      to eq(AlaveteliLocalization.locale.to_s)
    expect(writes).to eq(1)
  end
end
