require 'spec_helper'

RSpec.describe 'Your documents batched visibility checks' do
  include ActiveJob::TestHelper
  include DisclosuresCatalogueFixtures
  include_context 'with incoming attention off'
  include_context 'with document OCR off'

  it 'preserves eleven exact-list, query-budget and access checks at 500 documents per account' do
    alpha = FactoryBot.create(:user, trusted: true)
    beta = FactoryBot.create(:user, trusted: true)
    creator = FactoryBot.create(:admin_user)
    body = FactoryBot.create(:public_body)
    original = FactoryBot.create(:info_request,
                                 user: creator,
                                 public_body: body)
    message = AttachmentFixtures.deliver(
      original, [['records.txt', 'text/plain', "Invented records\n"]]
    )
    attachment = message.get_attachments_for_display.
      find { |row| row.filename == 'records.txt' }
    template = Disclosures::Creation.new(user: creator,
                                         attachment: attachment,
                                         kind: 'released_records').create!
    Disclosures::Publication.new(template.reload, user: creator).publish!
    base = expand_catalogue(template.reload, 1000)
    connection = ActiveRecord::Base.connection
    connection.execute("UPDATE info_requests SET user_id = CASE " \
                       "WHEN id % 2 = 0 THEN #{alpha.id} ELSE #{beta.id} END " \
                       "WHERE id > #{base}")
    # Ten attachments share each reply and request.
    connection.execute("UPDATE incoming_messages " \
                       "SET info_request_id = " \
                       "#{base} + ((id - #{base} - 1) % 100) + 1 " \
                       "WHERE id > #{base}")
    connection.execute("UPDATE foi_attachments " \
                       "SET incoming_message_id = " \
                       "#{base} + ((id - #{base} - 1) % 100) + 1 " \
                       "WHERE id > #{base}")
    connection.execute("UPDATE disclosure_documents " \
                       "SET info_request_id = " \
                       "#{base} + ((id - #{base} - 1) % 100) + 1, " \
                       "incoming_message_id = " \
                       "#{base} + ((id - #{base} - 1) % 100) + 1 " \
                       "WHERE id > #{base}")
    connection.execute("UPDATE disclosure_documents SET state = CASE " \
                       "WHEN id <= #{base + 200} THEN 'published' " \
                       "WHEN id <= #{base + 600} THEN 'draft' " \
                       "ELSE 'withdrawn' END WHERE id > #{base}")
    retained = Disclosures::Document.find(base + 1)
    retained.foi_attachment.update_columns(incoming_message_id: nil)
    retained.update_columns(request_deleted_at: Time.current,
                            owner_id: beta.id,
                            info_request_id: nil,
                            incoming_message_id: nil)
    sessions = [alpha, beta].to_h do |user|
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post('/profile/sign_in',
                   params: { user_signin: { email: user.email,
                                            password: 'jonespassword' } })
      expect(session.response).to have_http_status(:redirect)
      [user.id, session]
    end
    ids = ->(parity) do
      (1..1000).select { |number| number % 2 == parity }.reverse.
        map { |number| number.to_s.rjust(12, '0') }
    end
    expected_alpha = ids.call(0)
    expected_beta = ids.call(1)
    checks = []
    check = ->(label, user, expected) do
      queries = []
      callback = ->(*args) do
        payload = args.last
        unless payload[:cached] || payload[:name] == 'SCHEMA'
          queries << payload[:sql]
        end
      end
      response = nil
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(callback,
                                                'sql.active_record') do
          sessions[user.id].get('/documents/yours')
          response = sessions[user.id].response
        end
      end
      expect(response).to have_http_status(:ok), label
      expect(response.headers['Cache-Control']).to include('no-store')
      found = Nokogiri::HTML(response.body).
        css('.documents-panel__document a').map do |link|
          link['href'][%r{\A/documents/([^/]+)/manage\z}, 1]
        end
      expect(found).to eq(expected), label
      expect(queries.size).to be <= 50
      checks << { name: label,
                  documents: found.size,
                  uncached_sql: queries.size }
      queries.size
    end
    large = check.call('alpha_500_exact_order', alpha, expected_alpha)
    check.call('beta_500_including_retained_source', beta, expected_beta)
    rollback = ->(&block) do
      ActiveRecord::Base.transaction do
        block.call
        raise ActiveRecord::Rollback
      end
    end
    document = Disclosures::Document.find(base + 300)
    source = document.foi_attachment
    reply = source.incoming_message
    request = reply.info_request
    without_one = expected_alpha - [300.to_s.rjust(12, '0')]
    rollback.call do
      source.update_columns(prominence: 'hidden')
      check.call('hidden_attachment', alpha, without_one)
    end
    rollback.call do
      source.update_columns(erased_at: Time.current)
      check.call('erased_attachment', alpha, without_one)
    end
    without_request = expected_alpha.reject { |id| id.to_i % 100 == 0 }
    rollback.call do
      reply.update_columns(prominence: 'hidden')
      check.call('hidden_reply_ten_documents', alpha, without_request)
    end
    rollback.call do
      request.update_columns(prominence: 'hidden')
      check.call('hidden_request_ten_documents', alpha, without_request)
    end
    rollback.call do
      source.update_columns(incoming_message_id: nil)
      check.call('missing_reply', alpha, without_one)
    end
    rollback.call do
      InfoRequest.where('id > ?', base).where(user_id: alpha.id).where.
        not(id: request.id).update_all(user_id: creator.id)
      ten = check.call('ten_rows_same_budget',
                       alpha,
                       expected_alpha - without_request)
      expect(large).to be <= ten + 5
    end
    rollback.call do
      beta.update_columns(ban_text: 'Synthetic account ban')
      check.call('banned_owner', beta, expected_beta)
    end
    check.call('alpha_restored_after_rollbacks', alpha, expected_alpha)
    check.call('beta_restored_after_rollbacks', beta, expected_beta)
    expect(checks.size).to eq(11)
    puts "Document list: #{checks.to_json}"
  end

  # Cached statements and records count too: one authority translation and one
  # User per row would be query-cache hits that the uncached budget above never
  # sees.
  it 'loads each authority, request and requester once, and no versions, across many authorities' do
    owner = FactoryBot.create(:user, trusted: true)
    other = FactoryBot.create(:user, trusted: true)
    creator = FactoryBot.create(:admin_user)
    bodies = FactoryBot.create_list(:public_body, 20)
    original = FactoryBot.create(:info_request,
                                 user: creator,
                                 public_body: bodies.first)
    message = AttachmentFixtures.deliver(
      original, [['records.txt', 'text/plain', "Invented records\n"]]
    )
    attachment = message.get_attachments_for_display.
      find { |row| row.filename == 'records.txt' }
    template = Disclosures::Creation.new(user: creator,
                                         attachment: attachment,
                                         kind: 'released_records').create!
    Disclosures::Publication.new(template.reload, user: creator).publish!
    base = expand_catalogue(template.reload, 200)
    ids = bodies.map(&:id)
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL)
      UPDATE info_requests SET user_id = #{owner.id},
        public_body_id = (ARRAY[#{ids.join(',')}])[(id % 20) + 1],
        prominence = 'requester_only'
      WHERE id > #{base}
    SQL
    connection.execute("UPDATE disclosure_documents SET state = CASE " \
                       "WHEN id % 3 = 0 THEN 'draft' ELSE 'published' END " \
                       "WHERE id > #{base}")
    post '/profile/sign_in',
         params: { user_signin: { email: owner.email,
                                  password: 'jonespassword' } }

    measure = -> do
      seen = { uncached: [], cached: 0, records: Hash.new(0) }
      sql = ->(*args) do
        event = args.last
        if event[:cached]
          seen[:cached] += 1
        else
          (seen[:uncached] << event[:sql] unless event[:name] == 'SCHEMA')
        end
      end
      built = ->(*args) do
        event = args.last
        seen[:records][event[:class_name]] += event[:record_count]
      end
      ActiveSupport::Notifications.subscribed(sql, 'sql.active_record') do
        ActiveSupport::Notifications.subscribed(built,
                                                'instantiation.active_record') {
          get '/documents/yours'
        }
      end
      expect(response).to have_http_status(:ok)
      seen.merge(rows: Nokogiri::HTML(response.body).
                         css('.documents-panel__document').size)
    end

    get '/documents/yours' # so once-per-process lookups aren't measured
    many = measure.call
    expect(many[:rows]).to eq(200)
    expect(Nokogiri::HTML(response.body).css('.documents-panel__meta').
             map(&:text).uniq.size).to be >= 20
    expect(many[:uncached].grep(/disclosure_versions/)).to eq([])
    expect(many[:cached]).to be <= 60
    expect(many[:records]['User']).to be <= 2
    expect(many[:records]['InfoRequest']).to be <= 200
    expect(many[:records]['PublicBody']).to be <= 40

    InfoRequest.where('id > ?', base + 10).update_all(user_id: other.id)
    few = measure.call
    expect(few[:rows]).to eq(10)
    expect(many[:uncached].size).to eq(few[:uncached].size)
  end
end
