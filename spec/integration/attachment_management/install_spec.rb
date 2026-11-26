require 'spec_helper'

RSpec.describe 'Attachment management installation' do
  it 'adds its ability rules once however often Rails prepares' do
    3.times { Rails.application.reloader.prepare! }
    expect(Ability.ancestors.count(Ability::AttachmentRules)).to eq(1)
    expect(Ability.new(nil).can?(:manage_attachment, FoiAttachment.new)).
      to be false
  end

  it 'loads its classes from a reloadable namespace' do
    expect(Rails.autoloaders.main.cpath_expected_at(
             Rails.root.join('app/models/attachment_management/revision.rb')
           )).to eq('AttachmentManagement::Revision')
    expect(AttachmentManagement::Revision.table_name).
      to eq('attachment_management_revisions')
  end

  it 'registers the feature migrations once, alongside the attention migrations' do
    paths = Rails.application.config.paths['db/migrate'].to_a
    expect(paths.count { |path| path == Rails.root.join('db/migrate').to_s }).
      to eq(1)
    versions = ActiveRecord::MigrationContext.new(paths).migrations.
      map(&:version)
    expect(versions).to include(20261008000100)
    expect(ActiveRecord::Base.connection.
             table_exists?(:attachment_management_revisions)).to be true
  end

  it 'routes the management screens' do
    expect(Rails.application.routes.url_helpers.manage_attachment_path(12)).
      to eq('/manage/attachments/12')
    expect(Rails.application.routes.
             recognize_path('/manage/attachments/12/drafts/3/apply',
                            method: :post)).
      to include(controller: 'attachment_management/revisions', action: 'apply')
    other =
      begin
        Rails.application.routes.recognize_path('/manage/attachments/x')
      rescue StandardError
        {}
      end
    expect(other[:controller].to_s).not_to start_with('attachment_management')
  end

  it 'serves the editor modules through both import maps' do
    [Rails.application.importmap, Rails.application.admin_importmap].
      each do |importmap|
      helpers = ActionController::Base.helpers
      path = JSON.parse(importmap.to_json(resolver: helpers)).
        dig('imports', 'editor/box_editor')
      expect(path).to be_present
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).
        to include('redaction-boxes', 'export function Editor')
    end
  end

  it 'builds the editor styles into the site stylesheet' do
    get '/'
    css = Nokogiri::HTML(response.body).css('link[rel="stylesheet"]').
      map { |node| node['href'] }.
      find { |href| href.match?(%r{/responsive/application-\h+\.css}) }
    get css
    expect(response).to have_http_status(:ok)
    expect(response.body).
      to include('.redaction-box', '.attachment-management__confirm')
  end
end
