require 'spec_helper'

RSpec.describe 'Help from a help pack', type: :request do
  let(:page) { Nokogiri::HTML(response.body) }
  let(:older_pages) do
    %w[/help/about /help/requesting /help/unhappy /help/privacy /help/officers
       /help/api /help/credits /help/contact /help/alaveteli]
  end

  after { HelpSite.reset_root! }

  # Not a 404 page in tests: a missing route or action is raised as it is.
  def expect_no_page(path)
    get path
    expect(response).to have_http_status(:not_found), path
  rescue ApplicationController::RouteNotFound,
         AbstractController::ActionNotFound
    nil
  end

  context 'with no pack' do
    it 'lists the older help pages at /help' do
      get '/help'
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1.page-band__title').text).to eq('Help')
      expect(page.css('.help-site .help-rows a').map { _1['href'] }).
        to eq(%w[/help/about /help/requesting /help/unhappy /help/privacy
                 /help/officers /help/api /help/credits /help/contact])
    end

    it 'still serves the older help pages' do
      older_pages.each do |path|
        get path
        expect(response).to have_http_status(:ok), path
      end
    end

    it 'has no pack pages and an empty search' do
      %w[/help/words /help/guide /help/borrowing
         /help/borrowing/how-long].each { expect_no_page(_1) }
      get '/help/search'
      expect(response.parsed_body).to eq([])
    end

    it 'keeps About in the navigation' do
      get '/help'
      link = page.at_css('#navigation li.selected a')
      expect([link.text.strip, link['href']]).to eq(%w[About /help/about])
    end
  end

  context 'with a pack' do
    # The fixture pack, and the fixture theme's views for it: the partial
    # an answer's extra names.
    before do
      HelpSite.root = Rails.root.join('spec/fixtures/help_site').to_s
      @view_paths = HelpSiteController.view_paths
      HelpSiteController.prepend_view_path(
        Rails.root.join('spec/fixtures/help_site_views')
      )
    end

    after { HelpSiteController.view_paths = @view_paths }

    it 'serves every page of the pack, with its title in the band' do
      HelpSite.content.pages.each do |pack_page|
        get pack_page.path
        expect(response).to have_http_status(:ok), pack_page.path
        titles = page.css('.help-site header.page-band h1.page-band__title')
        expect(titles.size).to eq(1), pack_page.path
        expect(page.at_css('body')['class'].split).to include('band-view')
      end
    end

    it 'shows the sections on the front page' do
      get '/help'
      expect(page.at_css('h1.page-band__title').text).to eq('How can we help?')
      expect(page.at_css('title').text.strip).to start_with('Help')
      expect(page.css('.help-panel h3 a').map { [_1.text, _1['href']] }).
        to eq([['Borrowing books', '/help/borrowing'],
               ['Visiting', '/help/visiting']])
      find = page.at_css('[data-controller="help-find"]')
      expect(find['data-help-find-index-value']).to eq('/help/search')
    end

    it 'shows an answer with its related answers and its extra' do
      get '/help/borrowing/how-long'
      expect(page.at_css('.help-answer').text).to include('three weeks')
      expect(page.css('.help-rows--next a').map { _1['href'] }).
        to eq(%w[/help/borrowing/renewing])
      expect(page.at_css('a.help-word')['href']).to eq('/help/words#overdue')
    end

    it 'adds an answer’s extra from the theme’s help_site/extras' do
      get '/help/borrowing/renewing'
      expect(page.at_css('.help-answer .fixture-stamp').text).
        to eq('Stamped for “Can I renew a loan?”')
    end

    describe 'the reply deadline checker on an answer' do
      let(:path) { '/help/visiting/opening-hours' }
      let(:result) { page.at_css('.help-date__result').text.squish }
      let(:helpers) { ApplicationController.helpers }

      it 'offers today’s date, shut, with nothing worked out' do
        get path
        expect(page.at_css('details.help-date')['open']).to be_nil
        expect(page.at_css('details#help-deadline form')['action']).
          to eq("#{path}#help-deadline")
        expect(page.at_css('#help-date')['value']).
          to eq(Time.zone.today.iso8601)
        expect(page.css('#help-date-law option').map { _1['value'] }).
          to eq(%w[uk scotland])
        expect(page.at_css('.help-date__result')).to be_nil
      end

      it 'says when the reply is due, as request deadlines count it' do
        due = Deadlines::Calendar.
              working_days_after(Date.new(2026, 3, 2), 20, 'foi')
        get path, params: { received: '2026-03-02', where: 'uk' }
        expect(page.at_css('details.help-date')['open']).not_to be_nil
        expect(page.at_css('.help-date__result strong').text).
          to eq([due.strftime('%A'),
                 helpers.simple_date(due, format: :text)].join(' '))
        expect(result).to include('20 working days from then',
                                  'UK bank holidays')
        expect(page.at_css('#help-date')['value']).to eq('2026-03-02')
      end

      it 'counts Scotland’s bank holidays for an authority there' do
        get path, params: { received: '2026-03-20', where: 'scotland' }
        expect(result).to include('Scottish bank holidays')
        selected = page.at_css('#help-date-law option[selected]')
        expect(selected['value']).to eq('scotland')
      end

      it 'asks for a date when it is given something else' do
        get path, params: { received: 'soon' }
        expect(result).
          to eq('Choose the date the authority received your request.')
      end

      it 'stays open and asks for a date when the date is cleared' do
        get path, params: { received: '' }
        expect(page.at_css('details.help-date')['open']).not_to be_nil
        expect(page.at_css('#help-date')['value']).to be_nil
        expect(result).
          to eq('Choose the date the authority received your request.')
      end

      it 'keeps the answer in a frame of its own, apart from the form' do
        get path, params: { received: '2026-03-02' }
        expect(page.at_css('.help-date form')['data-turbo-frame']).
          to eq('help-deadline-answer')
        frame = page.at_css('turbo-frame#help-deadline-answer')
        expect(frame.at_css('.help-date__result strong')).to be_present
        expect(frame.at_css('input, select')).to be_nil
      end

      it 'says so when the date is past its bank holiday data' do
        get path, params: { received: '2027-12-20' }
        expect(result).to start_with('We can’t work out this deadline yet.')
        expect(page.at_css('.help-date__result strong')).to be_nil
      end
    end

    it 'keeps a mistake in the pack to the help pages' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'sections.yml'), 'groups: [')
        HelpSite.root = dir
        get '/help/about'
        expect(response).to have_http_status(:ok)
        link = page.at_css('#navigation li.selected a')
        expect([link.text.strip, link['href']]).to eq(%w[Help /help])
        expect { get '/help' }.to raise_error(Psych::SyntaxError)
      end
    end

    it 'puts a notice straight after the band' do
      user = FactoryBot.create(:user)
      post '/profile/sign_in', params: {
        user_signin: { email: user.email, password: 'jonespassword' },
        r: '/help/borrowing'
      }
      follow_redirect! while response.redirect?
      if page.at_css('#notice')
        expect(page.at_css('header.page-band + .band-flash #notice')).
          to be_present
      end
      expect(response.body).not_to include('after the band')
    end

    it 'explains the pack’s words' do
      get '/help/words'
      expect(page.css('.help-words dt').map { [_1['id'], _1.text] }).
        to eq([%w[overdue Overdue], ['reading-room', 'Reading Room']])
    end

    it 'gives the search box every answer' do
      get '/help/search'
      expect(response.parsed_body.map { _1['url'] }).
        to match_array(HelpSite.content.answers.values.map(&:path))
    end

    it '404s for an answer that does not exist, or one in the wrong section' do
      %w[/help/borrowing/no-such-answer /help/visiting/how-long
         /help/guide].each { expect_no_page(_1) }
    end

    it 'leaves the older help pages alone' do
      older_pages.each do |path|
        get path
        expect(response).to have_http_status(:ok), path
        expect(response.body).not_to include('help-site'), path
      end
    end

    it 'reads the pack once, however many pages are served' do
      allow(HelpSite::Content).to receive(:new).and_call_original
      HelpSite.reload!
      %w[/help /help/borrowing /help/borrowing/how-long /help/search
         /help/about].each { get _1 }
      expect(HelpSite::Content).to have_received(:new).once
    end

    it 'puts Help in the navigation' do
      get '/help/borrowing'
      link = page.at_css('#navigation li.selected a')
      expect([link.text.strip, link['href']]).to eq(%w[Help /help])
    end
  end
end
