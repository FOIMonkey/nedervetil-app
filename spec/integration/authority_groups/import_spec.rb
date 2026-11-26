require 'spec_helper'

RSpec.describe 'Authority groups: external release imports' do
  include DisclosuresHelpers

  let(:admin) { FactoryBot.create(:admin_user) }
  let!(:westmoor) do
    FactoryBot.create(:public_body,
                      name: 'Westmoor Borough Council',
                      tag_string: 'gss:E07000001')
  end
  let!(:eastbrook) do
    FactoryBot.create(:public_body, name: 'Eastbrook District Council')
  end
  let(:releases) { AuthorityGroups::ExternalRelease }

  def upload(text, filename: 'releases.csv')
    file = Tempfile.new(['releases', '.csv'])
    file.binmode
    file.write(text)
    file.rewind
    post '/admin/external_release_imports', params: {
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv',
                                         original_filename: filename)
    }
    AuthorityGroups::ReleaseImport.order(:id).last
  ensure
    file&.close!
  end

  def page
    Nokogiri::HTML(response.body)
  end

  before { sign_in(admin) }

  it 'previews without saving, then applies once' do
    csv = <<~CSV
      gss_code,body,authority,title,url,published_date,received_date,log_url
      E07000001,,,Parking permits issued,https://westmoor.example.invalid/foi/1,2026-07-20,,https://westmoor.example.invalid/foi
      ,#{eastbrook.url_name},,Bin collections,https://eastbrook.example.invalid/foi/2,,03/07/2026,
      ,,eastbrook district council,Street lighting,https://eastbrook.example.invalid/foi/3,2026-06-01T09:00:00Z,,
      ,nobody_here,,Unmatched,https://example.invalid/4,2026-07-01,,
      E07000001,,,Bad link,javascript:alert(1),2026-07-01,,
      E07000001,,,No date,https://westmoor.example.invalid/foi/5,,,
    CSV
    import = upload(csv)
    expect(response).
      to redirect_to("/admin/external_release_imports/#{import.id}")
    expect(releases.count).to eq(0)

    follow_redirect!
    expect(page.text.squish).to include('3 new · 0 already here', '3 problems')
    expect(page.css('table tbody tr').map { |row| row.css('td').map(&:text) }).
      to eq([['5', 'No authority matches.'],
             ['6', 'The link must be a web address starting http:// or ' \
                   'https://.'],
             ['7', 'No date, or not one this can read (use YYYY-MM-DD).']])

    post "/admin/external_release_imports/#{import.id}/apply"
    expect(releases.order(:released_on).
             pluck(:title, :released_on, :public_body_id)).
      to eq([['Street lighting', Date.new(2026, 6, 1), eastbrook.id],
             ['Bin collections', Date.new(2026, 7, 3), eastbrook.id],
             ['Parking permits issued', Date.new(2026, 7, 20), westmoor.id]])
    expect(import.reload).
      to have_attributes(state: 'applied', csv: nil, added_count: 3,
                         updated_count: 0, skipped_count: 3)
    expect(releases.find_by(title: 'Parking permits issued').log_url).to eq('https://westmoor.example.invalid/foi')

    post "/admin/external_release_imports/#{import.id}/apply"
    expect(flash[:error]).to eq('This import has already been applied.')
    expect(releases.count).to eq(3)
  end

  it 'updates known links on re-import, keeping admins’ edits, hiding and pins' do
    first = upload(<<~CSV)
      body,title,url,published_date
      #{westmoor.url_name},Parking,https://westmoor.example.invalid/foi/1,2026-07-20
      #{westmoor.url_name},Bins,https://westmoor.example.invalid/foi/2,2026-07-21
    CSV
    post "/admin/external_release_imports/#{first.id}/apply"
    parking = releases.find_by!(title: 'Parking')
    bins = releases.find_by!(title: 'Bins')
    parking.update!(title: 'Parking permits (edited)',
                    edited_at: Time.current, hidden_at: Time.current)
    bins.update!(pinned_at: Time.current)

    second = upload(<<~CSV)
      body,title,url,published_date
      #{westmoor.url_name},Parking again,HTTPS://WESTMOOR.example.invalid/foi/1#top,2026-07-22
      #{westmoor.url_name},Bin collections,https://westmoor.example.invalid/foi/2,2026-07-23
      #{westmoor.url_name},Bin collections twice,https://westmoor.example.invalid/foi/2,2026-07-23
    CSV
    get "/admin/external_release_imports/#{second.id}"
    expect(page.text.squish).to include('0 new · 2 already here', '1 problem')
    post "/admin/external_release_imports/#{second.id}/apply"

    expect(releases.count).to eq(2)
    expect(parking.reload).
      to have_attributes(title: 'Parking permits (edited)',
                         released_on: Date.new(2026, 7, 20))
    expect(parking).to be_hidden
    expect(bins.reload).
      to have_attributes(title: 'Bin collections twice',
                         released_on: Date.new(2026, 7, 23))
    expect(bins).to be_pinned
    expect(bins.external_release_import_id).to eq(first.id)
  end

  it 'hides and shows everything an import added' do
    import = upload(
      "body,title,url,published_date\n" \
      "#{westmoor.url_name},Parking,https://w.example.invalid/1,2026-07-20\n"
    )
    post "/admin/external_release_imports/#{import.id}/apply"
    post "/admin/external_release_imports/#{import.id}/hide_releases"
    expect(releases.visible.count).to eq(0)
    post "/admin/external_release_imports/#{import.id}/unhide_releases"
    expect(releases.visible.count).to eq(1)
  end

  it 'reads a spreadsheet’s Windows-1252 or byte-order-marked file' do
    text = "body,title,url,published_date\n#{westmoor.url_name}," \
           "Caf\xE9 licences,https://w.example.invalid/1,2026-07-20\n"
    import = upload(text.b)
    expect(import.result.rows.map(&:title)).to eq(['Café licences'])

    import = upload(
      "﻿body,title,url,published_date\n" \
      "#{westmoor.url_name},Licences,https://w.example.invalid/1,2026-07-20\n"
    )
    expect(import.result.rows.size).to eq(1)
  end

  it 'refuses a file without the columns it needs, or with too many rows' do
    import = upload("name,link\nWestmoor,https://w.example.invalid/1\n")
    expect(import.result.problems.map(&:message)).
      to eq(['Missing columns: body, gss_code or authority, title, ' \
             'published_date.'])

    stub_const('AuthorityFeeds::Reading::MAX_ROWS', 1)
    import = upload(
      "body,title,url,published_date\n" \
      "#{westmoor.url_name},A,https://w.example.invalid/1,2026-07-20\n" \
      "#{westmoor.url_name},B,https://w.example.invalid/2,2026-07-20\n"
    )
    expect(import.result.problems.map(&:message)).
      to eq(['More than 1 rows. Split the file.'])

    post '/admin/external_release_imports'
    expect(response).to have_http_status(422)
  end

  it 'refuses UTF-16 or NUL bytes before storing anything' do
    utf16 = "\uFEFFbody,title,url,published_date\n".encode('UTF-16LE').b
    expect { upload(utf16) }.
      not_to change(AuthorityGroups::ReleaseImport, :count)
    expect(response).to have_http_status(422)
    expect(page.text).to include('Save the file as CSV UTF-8 and try again.')
  end

  it 'refuses a line too long to be a release, and stops reading at the row limit' do
    stub_const('AuthorityFeeds::Reading::LINE_MAX', 80)
    import = upload(
      "body,title,url,published_date\n" \
      "#{westmoor.url_name},#{'x' * 100},https://w.example.invalid/1,2026-07-20\n"
    )
    expect(import.result.problems.map(&:message)).
      to eq(['A line is longer than 80 characters.'])

    stub_const('AuthorityFeeds::Reading::MAX_ROWS', 2)
    rows = Array.new(5) { |index| "#{westmoor.url_name},T,https://w.example.invalid/#{index},2026-07-20" }
    csv = AuthorityGroups::ReleaseCsv.
      new("body,title,url,published_date\n#{rows.join("\n")}\n")
    expect(csv.result.problems.map(&:message)).
      to eq(['More than 2 rows. Split the file.'])
    expect(csv.result.rows).to be_empty
  end

  it 'reads a file with headers only' do
    expect(AuthorityGroups::ReleaseCsv.
             new("body,title,url,published_date\n").result.to_h.
             slice(:rows, :problems)).
      to eq(rows: [], problems: [])
  end

  it 'imports thousands of rows in batches' do
    stub_const('AuthorityFeeds::BATCH', 500)
    rows = Array.new(2_000) { |index| "#{westmoor.url_name},Release #{index},https://w.example.invalid/#{index},2026-07-20" }
    import = upload("body,title,url,published_date\n#{rows.join("\n")}\n")
    post "/admin/external_release_imports/#{import.id}/apply"
    expect(releases.count).to eq(2_000)
    expect(import.reload.added_count).to eq(2_000)
  end
end
