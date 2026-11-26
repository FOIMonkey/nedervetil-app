require_relative 'attachment_fixtures'
require_relative 'disclosures_helpers'
require_relative 'disclosures_catalogue_fixtures'

module PublicationFeedHelpers
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include DisclosuresCatalogueFixtures

  def make_feed_document
    @feed_owner = FactoryBot.create(:user, name: 'Private requester marker')
    @feed_authority = FactoryBot.create(:public_body)
    @feed_source = FactoryBot.create(:info_request,
                                     user: @feed_owner,
                                     public_body: @feed_authority,
                                     title: 'Private source marker')
    @feed_admin = FactoryBot.create(:admin_user)
    message = AttachmentFixtures.deliver(
      @feed_source,
      [['ledger.txt', 'text/plain', "Public ledger repairs by ward\n"]]
    )
    attachment = message.get_attachments_for_display.
      find { |file| file.filename == 'ledger.txt' }
    document = Disclosures::Creation.new(user: @feed_owner,
                                         attachment: attachment,
                                         kind: 'released_records').create!
    document.reload.update!(title: 'Approved ledger',
                            document_date: Date.new(2020, 1, 1))
    publish(document, by: @feed_admin)
    document.reload.
      update_columns(first_published_at: 1.day.ago.change(usec: 0))
    document
  end

  def feed_path(cursor = nil)
    params = { mode: 'publications' }
    params[:cursor] = cursor if cursor
    '/documents.json?' + params.to_query
  end

  def feed_cursor(response)
    return unless response.headers['Link']

    URI.decode_www_form(URI(response.headers['Link'][/<([^>]+)>/, 1]).query).
      to_h.fetch('cursor')
  end

  def assert_feed(response)
    expect(response.status).to eq(200), response.body.first(200)
    expect(response.headers['Cache-Control']).to eq('private, no-store')
    expect(response.body).not_to include('Private source marker',
                                         'Private requester marker',
                                         'info_request_id',
                                         'user_id')
    rows = JSON.parse(response.body)
    expect(rows.size).to be <= 20
    rows.each do |row|
      expect(row.keys).
        to match_array(%w[id title description kind authority document_date
                          released_on published_at url])
    end
    rows
  end
end
