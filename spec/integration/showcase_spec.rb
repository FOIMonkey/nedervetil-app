require 'spec_helper'

RSpec.describe 'The "around the world" page' do
  include_context 'with production error pages'

  it 'is switched off' do
    get '/access-to-information-around-the-world'
    expect(response).to have_http_status(:not_found)
  end
end
