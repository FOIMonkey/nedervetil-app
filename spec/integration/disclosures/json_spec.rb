require 'spec_helper'

RSpec.describe 'Published document JSON' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include DisclosuresCatalogueFixtures
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Private requester marker') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:thread) do
    FactoryBot.create(:info_request,
                      user: owner,
                      title: 'Private source marker')
  end
  let(:document) do
    message = AttachmentFixtures.deliver(
      thread, [['ledger.txt', 'text/plain', "Public ledger repairs by ward\n"]]
    )
    attachment = message.get_attachments_for_display.
      find { |file| file.filename == 'ledger.txt' }
    made = Disclosures::Creation.new(user: owner,
                                     attachment: attachment,
                                     kind: 'released_records').create!
    made.reload.update!(title: 'Approved ledger',
                        document_date: Date.new(2020, 1, 1))
    publish(made, by: admin)
    made.reload
  end

  def catalogue(params = {}, headers = {})
    get '/documents.json', params: params, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq('private, no-store')
    expect(response.body).
      not_to include('Private source marker', 'Private requester marker')
    JSON.parse(response.body)
  end

  it 'keeps the existing array schema and exact ordering across page boundaries' do
    base = expand_catalogue(document, 45)
    ordered = (1..45).to_a.reverse.map { |id| id.to_s.rjust(12, '0') } +
              [document.public_id]
    seen = (1..3).flat_map do |page|
      data = catalogue(page: page)
      expect(data.map { |row| row['id'] }).
        to eq(ordered.slice((page - 1) * 20, 20))
      expect(data.first.keys).
        to match_array(%w[id title description kind authority
                          document_date released_on published_at url])
      data.map { |row| row['id'] }
    end
    expect(seen).to eq(ordered)
    expect(seen.uniq.size).to eq(46)
    expect(catalogue(page: 4)).to eq([])
    expect(catalogue(page: '999999999999999999999')).to eq([])
    expect(Disclosures::Search.new({}).pages).to eq(3)
    expect(Disclosures::Document.where('id > ?', base).count).to eq(45)
  end

  it 'uses stable ID tie breaking when dates and publication times coincide' do
    base = expand_catalogue(document, 22)
    ids = Disclosures::Document.where('id > ?', base).pluck(:id)
    Disclosures::Document.where(id: ids).
      update_all(published_at: document.published_at,
                 document_date: Date.new(2024, 1, 1))
    expect(catalogue.map { |row| row['id'] }).
      to eq((3..22).to_a.reverse.map { |id| id.to_s.rjust(12, '0') })
    expect(catalogue(page: 2).map { |row| row['id'] }).
      to eq(['000000000002', '000000000001', document.public_id])
  end

  it 'limits ID selection in SQL and batches metadata without instantiating private sources or previews' do
    expand_catalogue(document, 45)
    bodies = FactoryBot.create_list(:public_body, 6)
    Disclosures::Document.where('id > ?', 1_500_000_000).
      find_each.with_index do |doc, index|
        doc.update_columns(public_body_id: bodies[index % bodies.size].id)
      end
    queries = []
    models = Hash.new(0)
    sql = ActiveSupport::Notifications.subscribe(
      'sql.active_record'
    ) do |*, payload|
      if payload[:sql].start_with?('SELECT') && payload[:name] != 'SCHEMA'
        queries << payload[:sql]
      end
    end
    instantiations = ActiveSupport::Notifications.subscribe(
      'instantiation.active_record'
    ) do |*, payload|
      models[payload[:class_name]] += payload[:record_count]
    end
    ActiveRecord::Base.uncached do
      records = Disclosures::Search.new(page: 2).metadata_results
      expect(records.size).to eq(20)
      expect(
        records.map { |record| record.public_body.name }
      ).to all(be_present)
    end
    selection = queries.find do |query|
      query.match?(
        /\ASELECT (?:"disclosure_documents"\."id"|disclosure_documents.id) FROM/
      )
    end
    expect(selection).to match(/LIMIT /)
    expect(selection).to match(/OFFSET /)
    expect(models['Disclosures::Document']).to eq(20)
    expect(models.values_at('InfoRequest',
                            'IncomingMessage',
                            'FoiAttachment',
                            'ActiveStorage::Blob')).to all(eq(0))
  ensure
    ActiveSupport::Notifications.unsubscribe(sql) if sql
    ActiveSupport::Notifications.unsubscribe(instantiations) if instantiations
  end

  it 'filters and searches published metadata, excluding private request titles' do
    expand_catalogue(document, 25)
    approved_authority = document.public_body.name
    thread.update!(title: 'Changed private source marker',
                   public_body: FactoryBot.create(:public_body))
    data = catalogue(q: 'ledger',
                     body: document.public_body.url_name,
                     year: '2020',
                     file_type: 'text')
    expect(data.size).to eq(20)
    expect(data.map { |row| row['authority'] }).to all(eq(approved_authority))
    expect(catalogue(q: 'Changed private source')).to eq([])
  end

  it 'rechecks visibility after page IDs are selected, including conditional requests' do
    document
    allow_any_instance_of(Disclosures::Search).
      to receive(:entries).and_wrap_original do |read|
        entries = read.call
        document.update_columns(state: 'withdrawn')
        entries
      end
    expect(catalogue({}, { 'If-None-Match' => '*' })).to eq([])
  end

  it 'omits unsafe sources and withdrawals before pagination' do
    base = expand_catalogue(document, 25)
    Disclosures::Document.find(base + 25).update_columns(state: 'withdrawn')
    InfoRequest.find(base + 24).update_columns(prominence: 'hidden')
    IncomingMessage.find(base + 23).update_columns(prominence: 'hidden')
    FoiAttachment.find(base + 22).update_columns(erased_at: Time.current)
    FoiAttachment.find(base + 21).update_columns(prominence: 'requester_only')
    data = catalogue
    expect(data.size).to eq(20)
    expect(data.map { |row| row['id'] }).
      to eq((1..20).to_a.reverse.map { |id| id.to_s.rjust(12, '0') })
  end

  it 'keeps anonymous and unrelated Pro readers on the same public metadata with private sources' do
    document
    viewers = [nil, FactoryBot.create(:user)]
    viewers.each do |viewer|
      viewer ? sign_in(viewer) : reset!
      expect(catalogue.first['title']).to eq('Approved ledger')
      expect(response.headers['Set-Cookie']).to be_blank unless viewer
      get "/documents/#{document.public_id}/download"
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(document.bytes)
      get "/request/#{thread.url_title}.json"
      expect(response).to have_http_status(:not_found)
      get "/user/#{owner.url_name}.json"
      expect(response).to have_http_status(:not_found)
    end
    reset!
    get '/documents', headers: { 'Accept' => 'application/json' }
    expect(JSON.parse(response.body).first['title']).to eq('Approved ledger')
    head '/documents.json'
    expect(response).to have_http_status(:ok)
    expect(response.body).to be_empty
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end
end
