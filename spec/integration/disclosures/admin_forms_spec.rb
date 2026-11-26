require 'spec_helper'

RSpec.describe 'Administrative document forms' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: admin) }
  let(:document) do
    delivered_document(info_request, 'records.txt', 'text/plain',
                       "Ward total: 14\n", by: admin)
  end

  around do |example|
    with_setting(ActionController::Base, :allow_forgery_protection, true) do
      with_setting(ActionController::Base, :per_form_csrf_tokens, true) do
        example.run
      end
    end
  end

  def form(action)
    Nokogiri::HTML(response.body).at_css("form[action='#{action}']")
  end

  def token(form)
    form.at_css('[name=authenticity_token]')['value']
  end

  it 'withdraws through the admin form with its scoped CSRF token' do
    document
    publish(document, by: admin)
    sign_in(admin)
    get "/admin/documents/#{document.public_id}/manage"
    path = "/admin/documents/#{document.public_id}/withdraw"
    withdrawal = form(path)
    expect(withdrawal).to be_present
    post path, params: {
      authenticity_token: token(withdrawal), reason: 'Synthetic review'
    }
    expect(document.reload).to be_withdrawn
  end
end
