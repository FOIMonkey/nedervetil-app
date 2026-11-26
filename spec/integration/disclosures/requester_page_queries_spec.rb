require 'spec_helper'

RSpec.describe 'What a request page costs' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, trusted: true) }

  def statements(path)
    get path
    expect(response).to have_http_status(:ok)
    count = 0
    housekeeping = /\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/
    counter = ->(*, payload) do
      next if payload[:cached] || payload[:name] == 'SCHEMA' ||
              payload[:sql].match?(housekeeping)

      count += 1
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      get path
    end
    count
  end

  def request_with(documents:)
    request = FactoryBot.create(:info_request, user: owner)
    files = Array.new(documents) do |index|
      ["file#{index}.txt", 'text/plain', "Figures for depot #{index}\n"]
    end
    message = AttachmentFixtures.deliver(request, files)
    message.get_attachments_for_display.each do |part|
      Disclosures::Creation.new(user: owner, attachment: part,
                                kind: 'released_records').create!
    end
    request
  end

  def request_with_replies(count)
    request = FactoryBot.create(:info_request, user: owner)
    count.times do |index|
      AttachmentFixtures.deliver(request, [["note#{index}.txt", 'text/plain',
                                            "Update #{index}\n"]])
    end
    suggest_documents
    request
  end

  before { sign_in(owner) }

  it 'doesn’t run more statements for each document' do
    one = statements("/request/#{request_with(documents: 1).url_title}")
    three = statements("/request/#{request_with(documents: 3).url_title}")
    expect(three).to eq(one)
  end

  it 'doesn’t run more statements for each reply' do
    one = statements("/request/#{request_with_replies(1).url_title}")
    three = statements("/request/#{request_with_replies(3).url_title}")
    expect(three).to eq(one)
  end

  it 'doesn’t run more statements for each reply an admin sees' do
    requests = [2, 6].map do |replies|
      request = FactoryBot.create(:info_request, user: owner)
      replies.times do |index|
        message = AttachmentFixtures.deliver(
          request, [["note#{index}.txt", 'text/plain', "Update #{index}\n"]]
        )
        message.get_attachments_for_display.each do |part|
          Disclosures::Creation.new(user: owner, attachment: part,
                                    kind: 'released_records').create!
        end
      end
      request
    end
    suggest_documents
    sign_in(FactoryBot.create(:admin_user))
    few, many = requests.map do |request|
      statements("/request/#{request.url_title}")
    end

    expect(response.body.scan('attachment__document').size).to be >= 6
    expect(many).to eq(few)
  end

  # Counted with the repeats the query cache answers, which the examples above
  # leave out. A repeat is only answered when its values come in the same
  # order, and rows read without an order don't promise one.
  it 'reads the documents’ events once, for the requester and for an admin' do
    path = "/request/#{request_with(documents: 3).url_title}"
    loads = [owner, FactoryBot.create(:admin_user)].map do |user|
      sign_in(user)
      count = 0
      counter = ->(*, payload) do
        count += 1 if payload[:name] == 'Disclosures::Event Load'
      end
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        get path
      end
      expect(response).to have_http_status(:ok)
      count
    end

    expect(loads).to eq([1, 1])
  end

  it 'doesn’t run more statements for each document on the check step' do
    few, many = [2, 6].map do |documents|
      request = request_with(documents: documents)
      message = request.incoming_messages.first
      suggest_documents
      statements("/request/#{request.url_title}/publish/#{message.id}/check")
    end

    expect(response.body).to include('Anything to hide?')
    expect(many).to eq(few)
  end
end
