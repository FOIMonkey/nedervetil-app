require 'spec_helper'

RSpec.describe 'general/_site_wide_announcement' do
  let(:announcement) do
    FactoryBot.
      create(:announcement,
             content: '<b>Exciting news!</b> <script>alert("!")</script>')
  end

  before do
    allow(view).to receive(:current_user).and_return(FactoryBot.build(:user))
  end

  describe 'displaying an announcement' do
    it 'shows the announcement' do
      render template: 'general/_site_wide_announcement',
             locals: { announcement: announcement }
      expect(rendered).to include('Introducing projects')
      expect(rendered).to include('<b>Exciting news!</b>')
    end

    it 'leaves out a style block and its contents' do
      announcement.update!(content: '<style>.popup{display:none}</style>News')
      render template: 'general/_site_wide_announcement',
             locals: { announcement: announcement }
      expect(rendered).to include('News')
      expect(rendered).not_to include('display:none')
    end

    it 'strips out dangerous tags' do
      render template: 'general/_site_wide_announcement',
             locals: { announcement: announcement }
      expect(rendered).not_to include('<script>')
    end

    it 'dismisses through its own form, with no jQuery UJS needed' do
      render template: 'general/_site_wide_announcement',
             locals: { announcement: announcement }
      form = Nokogiri::HTML(rendered).at_css('form.popup__close-form')
      expect(form['action']).to end_with("/announcements/#{announcement.id}")
      expect(form.at_css('input[name="_method"]')['value']).to eq('delete')
      expect(form.at_css('button.popup__close')).to be_present
    end
  end
end
