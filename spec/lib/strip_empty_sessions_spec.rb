require 'spec_helper'

RSpec.describe StripEmptySessions do
  def make_response(session_data, response_headers, request_headers = {})
    app = ->(env) do
      env['rack.session'] = session_data
      [200, response_headers, ['content']]
    end

    app = StripEmptySessions.new(app, key: 'mykey', path: '', httponly: true)

    Rack::MockRequest.new(app).get('/', { HTTP_ACCEPT: 'text/html',
                                          lint: true }.merge(request_headers))
  end

  let(:application_response_headers) do
    { 'content-type' => 'text/html',
      'set-cookie' => 'mykey=f274c61a35320c52d45; path=/; HttpOnly'.freeze }
  end

  let(:no_set_cookie_header) do
    { 'content-type' => 'text/html' }
  end

  let(:several_set_cookie_headers) do
    { 'content-type' => 'text/html',
      'set-cookie' => ['mykey=f274c61a35320c52d45; path=/; HttpOnly',
                       'other=mydata'].freeze }
  end

  context 'there is meaningful data in the session' do
    let(:session_data) do
      { 'some_real_data' => 'important',
        'session_id' => 'my_session_id',
        '_csrf_token' => 'hi_there' }
    end

    it 'does not prevent a cookie being set' do
      response = make_response(session_data, application_response_headers)

      expect(response.headers['Set-Cookie']).
        to eq('mykey=f274c61a35320c52d45; path=/; HttpOnly')
    end

    it 'leaves the cookie alone when the browser sent one' do
      response = make_response(session_data, application_response_headers,
                               'HTTP_COOKIE' => 'mykey=f274c61a35320c52d45')

      expect(response.headers['Set-Cookie']).
        to eq('mykey=f274c61a35320c52d45; path=/; HttpOnly')
    end
  end

  context 'there is no meaningful data in the session' do
    let(:session_data) do
      { 'session_id' => 'my_session_id',
        '_csrf_token' => 'hi_there' }
    end

    it 'does not strip any other header' do
      response = make_response(session_data, application_response_headers)
      expect(response.headers['Content-Type']).to eq('text/html')
    end

    it 'strips the session cookie setting header ' do
      response = make_response(session_data, application_response_headers)
      expect(response.headers['Set-Cookie']).to be_nil
    end

    it 'deletes the cookie the browser sent, so it is not sent back again' do
      response = make_response(session_data, application_response_headers,
                               'HTTP_COOKIE' => 'mykey=f274c61a35320c52d45')
      expect(response.headers['Set-Cookie']).to match(/\Amykey=;/)
      expect(response.headers['Set-Cookie']).to match(/max-age=0/)
      expect(response.headers['Set-Cookie']).not_to include('f274c61a')
    end

    it 'leaves another cookie the browser sent alone' do
      response = make_response(session_data, application_response_headers,
                               'HTTP_COOKIE' => 'other=mydata')
      expect(response.headers['Set-Cookie']).to be_nil
    end

    it 'strips the session cookie setting header even with a locale' do
      session_data['locale'] = 'en'
      response = make_response(session_data, application_response_headers)
      expect(response.headers['Set-Cookie']).to be_nil
    end

    it 'does not strip the session cookie setting for admins' do
      session_data['using_admin'] = 1
      response = make_response(session_data, application_response_headers)

      expect(response.headers['Set-Cookie']).
        to eq('mykey=f274c61a35320c52d45; path=/; HttpOnly')
    end

    it 'strips only the session cookie setting header if there are several' do
      response = make_response(session_data, several_set_cookie_headers)
      expect(response.headers['Set-Cookie']).to eq('other=mydata')
    end

    it 'keeps several other cookies as they were' do
      headers = { 'content-type' => 'text/html',
                  'set-cookie' => ['mykey=f274c61a35320c52d45; path=/',
                                   'other=mydata', 'third=more'] }
      response = make_response(session_data, headers)
      expect(response.headers['Set-Cookie']).
        to eq(['other=mydata', 'third=more'])
    end

    it 'does not add a set-cookie header if the application does not set it' do
      response = make_response(session_data, no_set_cookie_header)
      expect(response.headers['Set-Cookie']).to be_nil
    end
  end
end
