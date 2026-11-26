require 'spec_helper'

# Bytes that are not valid UTF-8 would raise inside Rails wherever a page
# reads them. Rack::UTF8Sanitizer, first in the middleware stack, swaps each
# for the replacement character before anything else sees the request, so
# the visitor gets the page a mistyped address or form would get.
RSpec.describe 'A request with bytes that are not UTF-8', type: :request do
  include_context 'with production error pages'

  let(:replacement) { "�" }

  it 'searches for the words with the bad byte replaced' do
    get '/documents?q=caf%FF'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(name="q")).
      and include(%(value="caf#{replacement}"))
  end

  it 'treats a Latin-1 letter the same way, as it is not UTF-8 either' do
    get '/documents?q=caf%E9'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(value="caf#{replacement}"))
  end

  it 'answers that there is no such page when the bytes are in the address' do
    get '/help/abo%FFut'

    expect(response).to have_http_status(:not_found)
  end

  it 'takes a form, replacing the bad bytes in what was typed' do
    post '/help/contact',
         params: 'contact%5Bname%5D=Vin%FFny&' \
                 'contact%5Bemail%5D=vinny%40localhost&' \
                 'contact%5Bsubject%5D=A+question&' \
                 'contact%5Bmessage%5D=Where+do+I+start%FF&' \
                 'submitted_contact_form=1',
         headers: { 'Content-Type' => 'application/x-www-form-urlencoded',
                    'Origin' => "http://#{host}" }

    expect(response).to redirect_to(frontpage_path)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq('A question')
    expect(mail.body.to_s.force_encoding('UTF-8')).
      to start_with("Where do I start#{replacement}")
  end

  it 'serves the page when the bytes are in a header the browser sent' do
    get '/documents', headers: { 'Referer' => "http://elsewhere.example/\xFF".b,
                                 'User-Agent' => "Browser\xFF".b }

    expect(response).to have_http_status(:ok)
  end

  it 'serves the page when the bytes are in a cookie' do
    get '/documents', headers: { 'Cookie' => "seen=\xFF\xFE".b }

    expect(response).to have_http_status(:ok)
  end
end
