require 'spec_helper'

RSpec.describe 'Admin tags', type: :request do
  # Arrange a fully authenticated admin; production has no test-only bypass.
  before { sign_in users(:admin_user) }

  def page
    Nokogiri::HTML(response.body)
  end

  describe 'GET index' do
    def tags
      expect(response).to have_http_status(:ok)
      page.css('ul li > span.tag').map(&:text)
    end

    it 'shows the tags page' do
      get admin_tags_path
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq('Authority tags')
    end

    it 'raise 404 for unknown types' do
      expect { get admin_tags_path(model_type: 'unknown') }.to(
        raise_error ApplicationController::RouteNotFound
      )
    end

    it 'loads distinct tags' do
      FactoryBot.create(:public_body, tag_string: 'foo')
      FactoryBot.create(:public_body, tag_string: 'foo')

      get admin_tags_path(model_type: 'PublicBody')
      expect(tags).to include('foo').once
    end

    context 'with taggable model type' do
      before { FactoryBot.create(:public_body, tag_string: 'bar') }

      it 'loads tags with correct type' do
        get admin_tags_path(model_type: 'PublicBody')
        expect(tags).to include('bar')

        get admin_tags_path(model_type: 'InfoRequest')
        expect(tags).to_not include('bar')
      end
    end

    context 'with a different taggable model type' do
      before { FactoryBot.create(:info_request, tag_string: 'bar') }

      it 'loads tags with correct type' do
        get admin_tags_path(model_type: 'PublicBody')
        expect(tags).to_not include('bar')

        get admin_tags_path(model_type: 'InfoRequest')
        expect(tags).to include('bar')
      end
    end

    context 'with query' do
      before do
        FactoryBot.create(:public_body, tag_string: 'bar')
        FactoryBot.create(:public_body, tag_string: 'bar:123')
        FactoryBot.create(:public_body, tag_string: 'bar:124')
        FactoryBot.create(:public_body, tag_string: 'baz:123')
        FactoryBot.create(:public_body, tag_string: 'a_bar_b')
        FactoryBot.create(:public_body, tag_string: 'foo:bar123')
      end

      def search(query)
        get admin_tags_path(model_type: 'PublicBody', query: query)
      end

      it 'filter tags with tag name or value query' do
        search('bar')
        expect(tags).to include('bar')
        expect(tags).to include('bar:123')
        expect(tags).to include('bar:124')
        expect(tags).to_not include('baz:123')
        expect(tags).to include('a_bar_b')
        expect(tags).to include('foo:bar123')
      end

      it 'filter tags with tag name and value query' do
        search('bar:123')
        expect(tags).to_not include('bar')
        expect(tags).to include('bar:123')
        expect(tags).to_not include('bar:124')
        expect(tags).to_not include('baz:123')
        expect(tags).to_not include('a_bar_b')
        expect(tags).to_not include('foo:bar123')
      end

      it 'filter tags with tag begin with value query' do
        search(':123')
        expect(tags).to_not include('bar')
        expect(tags).to include('bar:123')
        expect(tags).to_not include('bar:124')
        expect(tags).to include('baz:123')
        expect(tags).to_not include('a_bar_b')
        expect(tags).to_not include('foo:bar123')
      end

      it 'filter tags with tag full name query' do
        search('bar:')
        expect(tags).to include('bar')
        expect(tags).to include('bar:123')
        expect(tags).to include('bar:124')
        expect(tags).to_not include('baz:123')
        expect(tags).to_not include('a_bar_b')
        expect(tags).to_not include('foo:bar123')
      end
    end
  end

  describe 'GET show' do
    def shown?(record)
      expect(response).to have_http_status(:ok)
      prefix = record.is_a?(PublicBody) ? 'body' : 'request'
      page.css("##{prefix}_#{record.id}").one?
    end

    it 'shows the page for the tag' do
      get admin_tag_path(tag: 'foo')
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq('Tag – foo')
    end

    it 'raise 404 for unknown types' do
      expect { get admin_tag_path(model_type: 'unknown', tag: 'foo') }.to(
        raise_error ApplicationController::RouteNotFound
      )
    end

    it 'loads notes' do
      note = FactoryBot.create(:note, notable_tag: 'foo')
      other_note = FactoryBot.create(:note, notable_tag: 'bar')

      get admin_tag_path(tag: 'foo')
      expect(response).to have_http_status(:ok)
      expect(page.css("#note_#{note.id}").size).to eq(1)
      expect(page.css("#note_#{other_note.id}")).to be_empty
    end

    it 'loads distinct taggings' do
      public_body = FactoryBot.create(:public_body, tag_string: 'foo foo:123')

      get admin_tag_path(model_type: 'PublicBody', tag: 'foo')
      expect(shown?(public_body)).to be(true)
    end

    context 'with taggable model type' do
      let!(:public_body) { FactoryBot.create(:public_body, tag_string: 'bar') }

      it 'loads taggings with correct type' do
        get admin_tag_path(model_type: 'PublicBody', tag: 'bar')
        expect(shown?(public_body)).to be(true)

        get admin_tag_path(model_type: 'InfoRequest', tag: 'bar')
        expect(shown?(public_body)).to be(false)
      end
    end

    context 'with a different taggable model type' do
      let!(:info_request) do
        FactoryBot.create(:info_request, tag_string: 'bar')
      end

      it 'loads taggings with correct type' do
        get admin_tag_path(model_type: 'PublicBody', tag: 'bar')
        expect(shown?(info_request)).to be(false)

        get admin_tag_path(model_type: 'InfoRequest', tag: 'bar')
        expect(shown?(info_request)).to be(true)
      end
    end

    context 'with query' do
      let!(:pb_1) { FactoryBot.create(:public_body, tag_string: 'foo') }
      let!(:pb_2) { FactoryBot.create(:public_body, tag_string: 'foo bar:123') }
      let!(:pb_3) { FactoryBot.create(:public_body, tag_string: 'foo bar:124') }
      let!(:pb_4) { FactoryBot.create(:public_body, tag_string: 'foo baz:123') }
      let!(:pb_5) { FactoryBot.create(:public_body, tag_string: 'foo a_bar_b') }
      let!(:pb_6) { FactoryBot.create(:public_body, tag_string: 'foo:bar123') }

      def search(query)
        get admin_tag_path(model_type: 'PublicBody', tag: 'foo', query: query)
      end

      it 'filter taggings with tag name or value query' do
        search('bar')
        expect(shown?(pb_1)).to be(false)
        expect(shown?(pb_2)).to be(true)
        expect(shown?(pb_3)).to be(true)
        expect(shown?(pb_4)).to be(false)
        expect(shown?(pb_5)).to be(true)
        expect(shown?(pb_6)).to be(true)
      end

      it 'filter taggings with tag name and value query' do
        search('bar:123')
        expect(shown?(pb_1)).to be(false)
        expect(shown?(pb_2)).to be(true)
        expect(shown?(pb_3)).to be(false)
        expect(shown?(pb_4)).to be(false)
        expect(shown?(pb_5)).to be(false)
        expect(shown?(pb_6)).to be(false)
      end

      it 'filter taggings with tag begin with value query' do
        search(':123')
        expect(shown?(pb_1)).to be(false)
        expect(shown?(pb_2)).to be(true)
        expect(shown?(pb_3)).to be(false)
        expect(shown?(pb_4)).to be(true)
        expect(shown?(pb_5)).to be(false)
        expect(shown?(pb_6)).to be(false)
      end

      it 'filter taggings with tag full name query' do
        search('bar:')
        expect(shown?(pb_1)).to be(false)
        expect(shown?(pb_2)).to be(true)
        expect(shown?(pb_3)).to be(true)
        expect(shown?(pb_4)).to be(false)
        expect(shown?(pb_5)).to be(false)
        expect(shown?(pb_6)).to be(false)
      end
    end
  end

  describe 'GET suggestions' do
    def tags
      expect(response).to have_http_status(:ok)
      JSON.parse(response.body)
    end

    it 'lists tags used more than once, most used first' do
      FactoryBot.create_list(:public_body, 2, tag_string: 'spec_pair')
      FactoryBot.create_list(:public_body, 3, tag_string: 'spec_triple')
      FactoryBot.create(:public_body, tag_string: 'spec_once')

      get suggestions_admin_tags_path(format: :json)

      expect(tags.select { |tag| tag['t'].start_with?('spec_') }).to eq(
        [{ 't' => 'spec_triple', 'c' => 3 }, { 't' => 'spec_pair', 'c' => 2 }]
      )
    end

    it 'only counts tags on the model being tagged' do
      FactoryBot.create_list(:public_body, 2, tag_string: 'spec_shared')
      FactoryBot.create_list(:info_request, 2, tag_string: 'spec_shared')

      get suggestions_admin_tags_path(model_type: 'InfoRequest', format: :json)

      expect(tags).to include('t' => 'spec_shared', 'c' => 2)
    end

    it 'defaults to public body tags' do
      FactoryBot.create_list(:info_request, 2, tag_string: 'spec_requests')

      get suggestions_admin_tags_path(format: :json)

      expect(tags.map { |tag| tag['t'] }).to_not include('spec_requests')
    end

    it 'raise 404 for unknown types' do
      expect {
        get suggestions_admin_tags_path(model_type: 'unknown', format: :json)
      }.to raise_error ApplicationController::RouteNotFound
    end
  end
end
