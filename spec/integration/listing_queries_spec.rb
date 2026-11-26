require 'spec_helper'

RSpec.describe 'What a list costs as it grows' do
  include_context 'with request limits off'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:user) { FactoryBot.create(:user, trusted: true) }

  # The statements a second view of the page runs, once the first has warmed
  # what's kept between views.
  def statements(path)
    get path
    follow_redirect! while response.redirect?
    expect(response).to have_http_status(:ok)
    path = request.fullpath
    list = []
    housekeeping = /\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/
    counter = ->(*, payload) do
      next if payload[:cached] || payload[:name] == 'SCHEMA' ||
              payload[:sql].match?(housekeeping)

      list << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      get path
    end
    expect(response).to have_http_status(:ok)
    list
  end

  # The page's cost with two rows, then with six.
  def growth(path)
    yield 2
    few = statements(path).size
    yield 4
    [few, statements(path).size]
  end

  it 'reads every admin user’s roles and tags together' do
    sign_in(admin)
    few, many = growth('/admin/users') do |count|
      count.times do
        listed = FactoryBot.create(:user, tag_string: 'press researcher')
        listed.add_role(:admin)
      end
    end

    expect(response.body).to include('press', 'label')
    expect(many).to eq(few)
  end

  it 'reads every snippet’s wording and tags together' do
    sign_in(admin)
    few, many = growth('/admin/snippets') do |count|
      count.times do
        FactoryBot.create(:outgoing_message_snippet,
                          name: "Refusal #{SecureRandom.hex(3)}")
      end
    end

    expect(response.body).to include('Refusal', 'exemption')
    expect(many).to eq(few)
  end

  it 'reads the dashboard’s announcements’ wording together' do
    sign_in(user)
    FactoryBot.create(:announcement, visibility: 'pro', title: 'First news')
    few = statements('/pro/dashboard').size
    FactoryBot.create_list(:announcement, 2,
                           visibility: 'pro', title: 'More news')
    many = statements('/pro/dashboard').size

    expect(response.body).to include('First news', 'More news')
    expect(many).to eq(few)
  end

  it 'reads the authority pages’ notes and their authorities together' do
    sign_in(admin)
    few, many = growth('/admin/authority_pages') do |count|
      count.times do |index|
        FactoryBot.create(:note, :tagged,
                          notable_tag: "tag_#{SecureRandom.hex(3)}",
                          rich_body: "Tagged advice #{index}")
        FactoryBot.create(:note, :for_public_body,
                          rich_body: "Authority advice #{index}")
      end
    end

    expect(response.body).to include('Tagged advice', 'Authority advice')
    expect(many).to eq(few)
  end

  it 'reads a draft batch’s authorities’ tags together' do
    sign_in(user)
    few, many = [2, 6].map do |count|
      draft = FactoryBot.create(:draft_info_request_batch, user: user)
      count.times do
        draft.public_bodies << FactoryBot.create(:public_body,
                                                 tag_string: 'council')
      end
      statements(
        "/pro/batch_request_authority_searches?draft_id=#{draft.id}"
      ).size
    end

    expect(response.body).to include('batch-builder__list__item__name')
    expect(many).to eq(few)
  end

  it 'reads a sent batch’s requests, authorities and deadlines together' do
    sign_in(user)
    few, many = [2, 6].map do |count|
      bodies = FactoryBot.create_list(:public_body, count)
      batch = FactoryBot.create(:info_request_batch,
                                user: user, public_bodies: bodies)
      batch.create_batch!
      batch.update!(sent_at: Time.zone.now)
      expect(batch.info_requests.count).to eq(count)
      # Each request's own censor rules are still read once for its name.
      statements("/info_request_batch/#{batch.id}").
        grep_v(/FROM censor_rules cr/).size
    end

    expect(response.body.scan('class="request_listing"').size).to eq(6)
    expect(many).to eq(few)
  end
end
