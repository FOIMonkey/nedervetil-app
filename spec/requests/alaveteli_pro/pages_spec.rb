require 'spec_helper'

RSpec.describe 'Pro pages', type: :request do
  describe 'GET show' do
    context 'when asked for an existing template' do
      before { get pro_page_path('legal') }

      it 'shows the page' do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Terms and conditions')
      end

      it 'is shown in the inbox area' do
        body = Nokogiri::HTML(response.body).at_css('body')
        expect(body['class']).to include('alaveteli-pro')
      end
    end

    context 'when asked for a template that does not exist' do
      it 'is not found' do
        get pro_page_path('nope')
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
