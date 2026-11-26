require 'spec_helper'

# A notice sits below the page's band, the home page's too, never between
# the masthead and the band (ApplicationHelper#band_notice).
RSpec.describe 'Where a notice is shown' do
  it 'puts the home page notice below its band' do
    post '/help/contact', params: {
      contact: { name: 'Vinny Vanilli', email: 'vinny@localhost',
                 subject: 'Why do I have such an ace name?', comment: '',
                 message: "You really should know!!!\n\nVinny" },
      submitted_contact_form: 1
    }
    expect(response).to redirect_to(frontpage_path)

    follow_redirect!
    body = response.body
    expect(body.scan('Your message has been sent').size).to eq(1)
    expect(body).to match(/<div id="notice" role="status"/)
    expect(body.index('band-flash')).to be > body.index('page-band--topics')
    expect(body.index('Your message has been sent')).
      to be > body.index('band-flash')
  end
end
