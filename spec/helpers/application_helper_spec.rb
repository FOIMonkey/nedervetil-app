require 'spec_helper'

RSpec.describe ApplicationHelper do
  include ApplicationHelper
  include LinkToHelper

  describe '#is_admin?' do
    before { session[:using_admin] = 1 }

    def signed_in_as(user)
      allow(helper).to receive(:can?) { |*args| Ability.new(user).can?(*args) }
    end

    it 'is true for an active admin' do
      signed_in_as(FactoryBot.create(:admin_user))
      expect(helper.is_admin?).to be(true)
    end

    it 'is false for a banned admin, though the session says admin' do
      signed_in_as(FactoryBot.create(:admin_user, ban_text: 'Banned'))
      expect(helper.is_admin?).to be(false)
    end

    it 'is false signed out, though the session says admin' do
      signed_in_as(nil)
      expect(helper.is_admin?).to be(false)
    end
  end

  describe '#can_ask_the_eu?' do
    it 'delegates to WorldFOIWebsites.can_ask_the_eu?' do
      expect(WorldFOIWebsites).to receive(:can_ask_the_eu?).with('US')
      can_ask_the_eu?('US')
    end
  end

  describe '#band_notice' do
    # Matches Rails' annotate_rendered_view_with_filenames output when empty.
    let(:only_comments) do
      "<!-- BEGIN app/views/general/_flashes.html.erb\n-->" \
        '<!-- END app/views/general/_flashes.html.erb -->'.html_safe
    end

    it 'places nothing when the notice partial holds only those comments' do
      allow(helper).to receive(:page_flashes).and_return(only_comments)
      expect(helper.band_notice).to be_nil
      expect(helper.band_notice_placed?).to be(false)
    end

    it 'places a notice wrapped in those comments' do
      # rubocop:disable Rails/OutputSafety -- fixed markup standing in for the flashes partial
      allow(helper).to receive(:page_flashes).and_return(
        only_comments.sub('-->', '--><div id="notice">Saved.</div>').html_safe
      )
      # rubocop:enable Rails/OutputSafety
      expect(helper.band_notice).to include('class="band-flash"', 'Saved.')
      expect(helper.band_notice_placed?).to be(true)
    end
  end

  describe '#page_band' do
    it 'draws the band for a view that none of the site\'s controllers drew' do
      band = helper.page_band('Title')
      expect(band).to include('class="page-band"', 'page-band__title', 'Title')
    end

    it 'draws a plain title when the controller says the page is in the ' \
       'sign-in dialog' do
      helper.controller.define_singleton_method(:in_sign_in_dialog?) { true }
      expect(helper.page_band('Title')).to eq('<h1>Title</h1>')
    end

    context 'with a notice to show' do
      before do
        allow(helper).to receive(:page_flashes).
          and_return('<div id="notice">Saved.</div>'.html_safe)
      end

      it 'puts the notice straight after the band' do
        expect(helper.page_band('Title')).
          to match(%r{</header><div class="band-flash".*Saved\.}m)
        expect(helper.band_notice_placed?).to be(true)
      end

      # The admin layout prints the notice itself, so here it would show twice.
      it 'leaves the notice to the layout on an admin page' do
        allow(helper).to receive(:controller).and_return(AdminController.new)
        band = helper.page_band('Title')
        expect(band).to include('page-band__title')
        expect(band).not_to include('band-flash', 'Saved.')
        expect(helper.band_notice_placed?).to be(false)
      end
    end
  end

  describe '#render_flash' do
    it 'returns a string when given a string' do
      expect(render_flash('some text')).to eq('some text')
    end

    it 'correctly resymbolizes the hash keys and calls render' do
      flash = { 'inline' => 'some text' }
      expect(render_flash(flash)).to eq('some text')
    end
  end

  describe '#inside_layout' do
    it 'passes captured ERB to a layout without treating it as a template' do
      literal = '<%= 1 + 1 %>'.html_safe
      expect(helper).to receive(:render).with(template: 'layouts/admin') do
        helper.view_flow.get(:layout)
      end

      expect(helper.inside_layout('admin') { literal }).to eq(literal)
    end

    it 'restores the previous layout content after rendering' do
      previous_content = '<p>previous</p>'.html_safe
      helper.view_flow.set(:layout, previous_content)
      allow(helper).to receive(:render).and_return('rendered')

      helper.inside_layout('admin') { '<p>inside</p>'.html_safe }

      expect(helper.view_flow.get(:layout)).to eq(previous_content)
    end
  end

  describe '#read_asset_file' do
    it "raises an Exception if it can't find the file" do
      expect { read_asset_file('nosuchfile.css') }.
        to raise_error(Propshaft::MissingAssetError,
                       "The asset 'nosuchfile.css' was not found in the " \
                       "load path.")
    end

    it 'returns the built stylesheet, with its images at their asset URLs' do
      css = read_asset_file('responsive/application.css')
      expect(css).to match(/font-size/)
      expect(css).to match(%r{url\("/assets/status/status-sprite-\h{8}\.png"\)})
    end

    it 'returns the file content as UTF-8' do
      expect(read_asset_file('responsive/application.css').encoding.to_s).
        to eq('UTF-8')
    end
  end

  describe '#theme_installed?' do
    let(:paths) { %w[theme_path app_path] }

    let(:view_paths) { double(ActionView::PathSet, paths: paths) }

    it 'returns true if there is an installed theme' do
      expect(theme_installed?).to eq true
    end

    context 'no theme is installed' do
      let(:paths) { ['app_path'] }

      it 'returns false' do
        expect(theme_installed?).to eq false
      end
    end
  end

  describe '#theme_asset_exists?' do
    let(:theme_view_path) do
      File.dirname(__FILE__) + "/../../lib/themes/alavetelitheme/lib/views"
    end

    let(:app_view_path) { File.dirname(__FILE__) + "/../../app/views" }

    let(:paths) do
      [
        theme_view_path,
        app_view_path
      ]
    end

    let(:view_paths) { double(ActionView::PathSet, paths: paths) }

    it 'looks in the theme file path' do
      expected_path = theme_view_path.gsub('/lib/views', '/app/assets')
      allow(File).to receive(:exist?).and_call_original

      theme_asset_exists?('images/logo.png')
      expect(File).to have_received(:exist?).
        with(expected_path + "/images/logo.png")
    end

    it 'returns false if the file does not exist' do
      expect(theme_asset_exists?('images/imaginary.png')).to eq false
    end

    it 'returns true if the file exists' do
      Dir.mktmpdir do |theme|
        images = File.join(theme, 'app/assets/images')
        FileUtils.mkdir_p(images)
        FileUtils.touch(File.join(images, 'logo-opengraph.png'))
        allow(view_paths).to receive(:paths).
          and_return([File.join(theme, 'lib/views'), app_view_path])
        expect(theme_asset_exists?('images/logo-opengraph.png')).to eq true
      end
    end

    context 'without a theme installed' do
      let(:paths) { [app_view_path] }

      it 'looks in the core app file path' do
        expected_path = app_view_path.gsub('/app/views', '/app/assets')
        allow(File).to receive(:exist?).and_call_original

        theme_asset_exists?('images/logo.png')
        expect(File).to have_received(:exist?).
          with(expected_path + "/images/logo.png")
      end

      it 'returns true if the file exists' do
        expect(theme_asset_exists?('images/social-facebook.png')).to eq true
      end
    end
  end

  describe 'when creating an event description' do
    it 'should generate a description for a request' do
      @info_request = FactoryBot.create(:info_request)
      @sent_event = @info_request.last_event
      public_body_link = public_body_link_absolute(@info_request.public_body)
      request_user_link = request_user_link_absolute(@info_request)
      expected = "Request sent to #{public_body_link} by #{request_user_link}"
      expect(event_description(@sent_event)).to match(expected)
    end

    it 'should generate a description for a response' do
      @info_request_with_incoming = FactoryBot.create(
        :info_request_with_incoming
      )
      @response_event = @info_request_with_incoming.last_event
      public_body_link = public_body_link_absolute(
        @info_request_with_incoming.public_body
      )
      request_user_link = request_user_link_absolute(
        @info_request_with_incoming
      )
      expected = "Response by #{public_body_link} to #{request_user_link}"
      expect(event_description(@response_event)).to match(expected)
    end

    it 'should generate a description for a request where an internal review has been requested' do
      @info_request_with_internal_review_request = FactoryBot.
        create(:info_request_with_internal_review_request)
      @response_event = @info_request_with_internal_review_request.last_event
      public_body_link = public_body_link_absolute(
        @info_request_with_internal_review_request.public_body
      )
      request_user_link = request_user_link_absolute(
        @info_request_with_internal_review_request
      )
      expected = "Internal review request sent to #{public_body_link} by " \
        "#{request_user_link}"
      expect(event_description(@response_event)).to match(expected)
    end
  end

  describe 'site_wide_announcement' do
    let(:current_user) { FactoryBot.create(:user) }

    it 'calls scopes on Announcement' do
      announcement = double(:announcement)
      relation = double(:announcement_relation)
      dismissal = double(:dismissal)
      session[:announcement_dismissals] = dismissal

      allow(Announcement).to receive(:site_wide_for_user).
        with(current_user, dismissal).
        and_return(relation)
      allow(relation).to receive(:first).
        and_return(announcement)

      expect(site_wide_announcement).to eq announcement
    end
  end

  describe '#cache_if_caching_fragments' do
    subject(:result) do
      cache_if_caching_fragments('key') { block_result }
    end

    let(:block_result) { :block_result }

    context 'when fragment caching is enabled' do
      before do
        allow(AlaveteliConfiguration).to receive(:cache_fragments).
          and_return(true)
        allow(AlaveteliLocalization).to receive(:locale).and_return('en')
        allow(self).to receive(:cache).and_yield.and_return(:cached_result)
      end

      it 'calls cache with the provided arguments and locale' do
        cache_if_caching_fragments('key') { block_result }
        expect(self).to have_received(:cache).with(%w[key en])
      end

      it 'yields the block within the cache block' do
        expect(result).to eq(:cached_result)
      end
    end

    context 'when fragment caching is disabled' do
      before do
        allow(AlaveteliConfiguration).to receive(:cache_fragments).
          and_return(false)
      end

      it 'does not call cache' do
        cache_if_caching_fragments('key') { block_result }
        expect(self).not_to receive(:cache)
      end

      it 'yields the block directly' do
        expect(result).to eq(:block_result)
      end
    end
  end

  describe '#large_file_size' do
    it 'gives the size of a file of a megabyte or more' do
      expect(large_file_size(3.5.megabytes)).to eq('3.5 MB')
    end

    it 'gives nothing for a smaller file, or an unknown size' do
      expect(large_file_size(324)).to be_nil
      expect(large_file_size(1.megabyte - 1)).to be_nil
      expect(large_file_size(nil)).to be_nil
    end
  end
end
