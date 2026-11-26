require 'spec_helper'

RSpec.describe 'Disclosures installation' do
  # The document callbacks on each model, by callback chain.
  def document_callback_counts
    {
      InfoRequest => { destroy: %i[destroy_documents] },
      CensorRule => { commit: %i[censor_published_documents] }
    }.flat_map do |model, chains|
      chains.flat_map do |kind, names|
        names.map do |name|
          count = model.public_send(:"_#{kind}_callbacks").
                  count { |callback| callback.filter == name }
          ["#{model.name}.#{kind}.#{name}", count]
        end
      end
    end.to_h
  end

  it 'declares its ability rules and document callbacks once however often Rails prepares' do
    before = document_callback_counts
    3.times { Rails.application.reloader.prepare! }
    expect(Ability.ancestors.count(Ability::DocumentRules)).to eq(1)

    expect(document_callback_counts).to eq(before)
    expect(before.values).to all(eq(1))
  end

  it 'loads all its classes' do
    expect(
      Rails.autoloaders.main.
        cpath_expected_at(Rails.root.join('app/models/disclosures/document.rb'))
    ).to eq('Disclosures::Document')
    expect { Rails.autoloaders.main.eager_load_namespace(Disclosures) }.
      not_to raise_error
    expect(Disclosures::Document.table_name).to eq('disclosure_documents')
  end

  it 'runs the jobs that call converters on the documents queue, away from incoming mail' do
    expect(AttachmentManagement::ProcessJob.queue_name).to eq('documents')
    expect(Disclosures::SuggestJob.queue_name).to eq('low')
  end

  it 'registers its migration, once, and its tables exist' do
    paths = Rails.application.config.paths['db/migrate'].to_a
    expect(paths.count { |path| path == Rails.root.join('db/migrate').to_s }).
      to eq(1)
    versions = ActiveRecord::MigrationContext.new(paths).migrations.
      map(&:version)
    expect(versions).to include(20261013000100)
    expect(versions).not_to include(20261013000200)
    applied = ActiveRecord::Base.connection_pool.schema_migration.versions
    expect(applied).to include('20261013000100')

    connection = ActiveRecord::Base.connection
    %i[disclosure_documents disclosure_pages disclosure_page_words
       disclosure_events disclosure_suggestions].each do |table|
      expect(connection.table_exists?(table)).to be(true), "#{table} is missing"
    end
    expect(connection.column_exists?(:disclosure_documents, :released_on)).
      to be true
    expect(connection.table_exists?(:disclosure_versions)).to be false
  end

  describe 'routes' do
    include_context 'with production error pages'

    def route(path, method: :get)
      Rails.application.routes.recognize_path(path, method: method)
    end

    it 'sends /documents and a twelve-character id to the document screens' do
      expect(route('/documents')).
        to include(controller: 'disclosures/documents', action: 'index')
      expect(route('/documents', method: :post)).
        to include(controller: 'disclosures/documents', action: 'create')
      expect(route('/documents/abcdefghij12')).to include(
        controller: 'disclosures/documents', action: 'show', id: 'abcdefghij12'
      )
      expect(route('/documents/abcdefghij12/pages/3')).
        to include(action: 'page_image', page: '3')
      expect(Rails.application.routes.url_helpers.
               disclosure_document_path('abcdefghij12')).
        to eq('/documents/abcdefghij12')
    end

    it 'leaves any other id, short or upper case, to core’s not found' do
      %w[/documents/abc /documents/ABCDEFGHIJKL /documents/abcdefghij12x
         /documents/abcdefghij12/pages/x].each do |path|
        expect(route(path)).
          to include(controller: 'general', action: 'not_found'), path
      end

      get '/documents/ABCDEFGHIJKL'
      expect(response).to have_http_status(:not_found)
    end

    it 'leaves core’s request and attachment routes and Manage’s alone, and sends the old search to the documents' do
      expect(route('/request/pothole_repairs')).
        to include(controller: 'request', action: 'show')
      expect(route('/request/pothole_repairs/response/7/attach/2/letter.pdf')).
        to include(controller: 'attachments', action: 'show', part: '2')
      get '/search/pothole'
      expect(response).to redirect_to('/documents?q=pothole')
      expect(route('/manage/attachments/1')).
        to include(controller: 'attachment_management/attachments',
                   action: 'show')
    end
  end
end
