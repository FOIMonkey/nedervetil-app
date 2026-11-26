require 'spec_helper'

RSpec.describe PlainTextTranslation do
  let(:name) { "Tom & Jerry's" }

  def rendered(controller, format, template = "<%= _('From {{name}}', name: name) %>")
    controller.render(inline: template,
                      locals: { name: name },
                      formats: [format])
  end

  it 'leaves values as written when a text template is the output' do
    expect(rendered(RequestController, :text)).to eq("From Tom & Jerry's")
  end

  it 'does the same for plurals' do
    template = "<%= n_('{{count}} reply from {{name}}', " \
               "'{{count}} replies from {{name}}', " \
               "2, count: 2, name: name) %>"
    expect(rendered(RequestController, :text, template)).
      to eq("2 replies from Tom & Jerry's")
  end

  it 'still escapes them in HTML' do
    expect(rendered(RequestController, :html)).
      to eq('From Tom &amp; Jerry&#39;s')
  end

  it 'leaves other controllers’ text renders escaped, as they may go into a page' do
    expect(rendered(Admin::PublicBodiesController, :text)).
      to eq('From Tom &amp; Jerry&#39;s')
  end

  it 'writes values as they are into text made outside a view or mailer' do
    text = described_class._('From {{name}}', name: name)
    expect(text).to eq("From Tom & Jerry's")
    expect(text).not_to be_html_safe
  end

  it 'does the same for plurals made outside a view or mailer' do
    text = described_class.n_(
      '{{count}} reply from {{name}}',
      '{{count}} replies from {{name}}',
      2,
      count: 2,
      name: name
    )
    expect(text).to eq("2 replies from Tom & Jerry's")
    expect(text).not_to be_html_safe
  end

  it 'writes names into plain-text emails as they are' do
    body = FactoryBot.create(:public_body,
                             name: 'Children’s Services & Schools')
    mail = RequestMailer.
      requires_admin(FactoryBot.create(:info_request, public_body: body))
    expect(mail.body.to_s).to include('Children’s Services & Schools')
    expect(mail.body.to_s).not_to include('&amp;')
  end

  it 'gives mailers plain-text subjects' do
    allow(AlaveteliConfiguration).
      to receive(:site_name).and_return("Tom & Jerry's FOI")
    mail = UserMailer.confirm_login(FactoryBot.create(:user),
                                    {},
                                    'http://test.host/c/1')
    expect(mail.subject).to eq("Confirm your account on Tom & Jerry's FOI")
  end
end
