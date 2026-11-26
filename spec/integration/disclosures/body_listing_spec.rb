require 'spec_helper'

RSpec.describe 'Authority list pages' do
  include PublicationFeedHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let!(:document) { make_feed_document }

  def statements
    queries = []
    listener = ->(*, payload) do
      unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
        queries << payload[:sql]
      end
    end
    ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
      yield
    end
    queries
  end

  def normalised
    response.body.
      gsub(/(<meta name="csrf-token" content=")[^"]*/, '\1X').
      gsub(/(<meta name="csp-nonce" content=")[^"]*/, '\1X').
      gsub(/(name="authenticity_token" value=")[^"]*/, '\1X').
      gsub(/nonce="[^"]*"/, 'nonce="X"').
      gsub(/(Printed from \S+ on )[^<\n]*/, '\1T')
  end

  def bodies(count, offset: 0)
    Array.new(count) do |index|
      tags = ['synthetic_group', ('gss:E09000001' if index.even?),
              ('scotland' if index == 1)].compact.join(' ')
      FactoryBot.create(:public_body,
                        name: "Synthetic Authority #{offset + index}",
                        tag_string: tags)
    end
  end

  def rows
    Nokogiri::HTML(response.body).
      css('.body_listing .body-listing__header a').
      map { |link| link.text.strip }
  end

  # Without preloading the bodies' associations, so each row loads its own.
  def unbatched
    allow_any_instance_of(ActiveRecord::Associations::Preloader).
      to receive(:call).and_wrap_original do |original|
        original.call unless original.receiver.records.first.is_a?(PublicBody)
      end
    yield
  ensure
    allow_any_instance_of(ActiveRecord::Associations::Preloader).
      to receive(:call).and_call_original
  end

  # Search is not under test: both typeaheads get these bodies as their
  # results, loaded as AuthorityQuery#results loads them.
  def search_ahead_results(ids)
    [PublicBodyController, RequestController].each do |controller|
      allow_any_instance_of(controller).
        to receive(:typeahead_search) do |instance, *|
          instance.instance_variable_set(:@page, 1)
          instance.instance_variable_set(:@per_page, 25)
          found = PublicBody.includes(:translations, :tags).
                  where(id: ids).order(:id).map { |body| { model: body } }
          Struct.new(:results, :matches_estimated).new(found, found.size)
        end
    end
  end

  before do
    Note.create!(notable_tag: 'synthetic_group',
                 style: 'original',
                 body: 'Synthetic tag note: one FOI office.')
    Note.create!(notable_tag: 'gss:E09000001',
                 style: 'yellow',
                 rich_body: '<div>Synthetic caveat for one area.</div>')
  end

  it 'shows each authority with no count and no notes, and no Ask EU link, in the same statements however many rows' do
    listed = bodies(3)
    Note.create!(notable: listed.first,
                 style: 'blue',
                 rich_body: '<div>Synthetic note for one authority.</div>')
    base = expand_catalogue(document, 5)
    Disclosures::Document.where('id > ?', base).
      order(:id).each_with_index do |record, index|
        record.update_columns(public_body_id: listed[index % 2].id)
      end
    get '/body/list/all'
    few = statements { get '/body/list/all' }
    expect(response).to have_http_status(:ok)
    expect(rows).to include(*listed.map(&:name), @feed_authority.name)
    expect(Nokogiri::HTML(response.body).css('.body_listing').text).
      not_to include('published document')
    expect(response.body).not_to include('Synthetic note for one authority.',
                                         'Synthetic tag note',
                                         'Synthetic caveat for one area.')
    expect(response.body).not_to include('Ask EU Authorities')

    bodies(27, offset: 3)
    many = statements { get '/body/list/all' }
    expect(rows.size).to eq(PublicBody.visible.count)
    expect(many.size).to eq(few.size)
  end

  it 'renders the list exactly as row-by-row loading does, for a visitor, a Pro user and an admin' do
    listed = bodies(4)
    Note.create!(notable: listed.last,
                 style: 'original',
                 body: 'Synthetic plain note.')
    expand_catalogue(document, 2)
    listing_paths = %w[/body/list/all /body/list/s]
    [nil, FactoryBot.create(:user),
     FactoryBot.create(:admin_user)].each do |user|
      reset!
      if user
        post '/profile/sign_in',
             params: { user_signin: { email: user.email,
                                      password: 'jonespassword' } }
      end
      listing_paths.each do |path|
        get path
        batched = normalised
        unbatched { get path }
        expect(normalised).
          to eq(batched), "#{path} as #{user&.name || 'a visitor'}"
      end
      get '/body/list/all', params: { public_body_query: 'Synthetic' }
      batched = normalised
      unbatched do
        get '/body/list/all', params: { public_body_query: 'Synthetic' }
      end
      expect(normalised).to eq(batched)
    end
  end

  it 'loads both authority typeaheads in the same statements for any number of results, and renders them unchanged' do
    listed = bodies(3)
    more = bodies(21, offset: 3)
    %w[/body/search_ahead /select_authority].each do |path|
      search_ahead_results(listed.map(&:id) + [@feed_authority.id])
      get path, params: { query: 'Synthetic' }
      few = statements { get path, params: { query: 'Synthetic' } }
      expect(response).to have_http_status(:ok)
      expect(rows).to include(@feed_authority.name), path
      batched = normalised
      row_by_row = statements do
        unbatched { get path, params: { query: 'Synthetic' } }
      end
      expect(normalised).to eq(batched), path
      expect(row_by_row.size).to be > few.size

      search_ahead_results(more.map(&:id) + listed.map(&:id))
      many = statements { get path, params: { query: 'Synthetic' } }
      expect(rows.size).to eq(24)
      expect(many.size).to eq(few.size), path
    end
  end
end
