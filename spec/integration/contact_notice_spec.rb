require 'spec_helper'

# A notice that travels a redirect chain to a band page: the contact form
# redirects to the home page when the message has gone, and signed in the
# home page redirects to the inbox, where the notice sits below the band
# (ApplicationHelper#band_notice).
RSpec.describe 'The contact form, signed in', type: :request do
  it 'shows its notice below the inbox band' do
    user = FactoryBot.create(:user)
    sign_in(user)

    post '/help/contact', params: {
      contact: { name: user.name, email: user.email,
                 subject: 'A question', comment: '',
                 message: "Where do I find my requests?\n" },
      submitted_contact_form: 1
    }
    expect(response).to redirect_to(frontpage_url)
    follow_redirect!
    expect(response).to redirect_to(alaveteli_pro_dashboard_path)
    follow_redirect!

    notice = Nokogiri::HTML(response.body).
             at_css('.page-band + .band-flash #notice')
    expect(notice.text).to include('Your message has been sent')
  end
end
