require 'spec_helper'

RSpec.describe ActionController::Base, type: :controller do
  render_views

  controller(ActionController::Base) do
    def payload
      render json: { text: "</script><>&\u2028\u2029" }
    end

    def redirect
      redirect_to params[:target]
    end
  end

  before do
    routes.draw do
      get 'payload' => 'anonymous#payload'
      get 'redirect' => 'anonymous#redirect'
    end
  end

  it 'returns valid JSON with literal HTML characters and JS separators' do
    get :payload, format: :json
    expect(response.media_type).to eq('application/json')
    expect(JSON.parse(response.body)['text']).to eq("</script><>&\u2028\u2029")
    expect(response.body).to include("</script><>&\u2028\u2029")
  end

  it 'rejects path-relative redirects' do
    expect { get :redirect, params: { target: 'example.test' } }.
      to raise_error(ActionController::Redirecting::UnsafeRedirectError)
  end

  it 'allows a root-relative redirect' do
    get :redirect, params: { target: '/signin' }
    expect(response).to redirect_to('/signin')
  end

  it 'still escapes JSON embedded in an HTML attribute' do
    payload = { text: '</script><script>alert(1)</script>"' }.to_json
    html = ApplicationController.helpers.tag.div(data: { payload: payload })
    node = Nokogiri::HTML.fragment(html)
    expect(node.css('script')).to be_empty
    expect(JSON.parse(node.at_css('div')['data-payload'])).
      to eq(JSON.parse(payload))
  end

  it 'omits autocomplete on hidden fields' do
    html = ApplicationController.helpers.hidden_field_tag('token', 'example')
    expect(Nokogiri::HTML.fragment(html).at_css('input')['autocomplete']).
      to be_nil
  end
end
