require 'spec_helper'

RSpec.describe 'Admin queue queries' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with request limits off'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:body) do
    FactoryBot.create(:public_body, name: 'Synthetic County Council')
  end
  let(:requesters) do
    ['Rowan Requester', 'Avery Quillfeather',
     'Morgan Example', 'Dr Sam Placeholder'].map do |name|
      FactoryBot.create(:user, name: name)
    end
  end

  def draft_for(user, text)
    request = FactoryBot.create(:info_request,
                                user: user,
                                public_body: body,
                                title: "Gritting routes #{SecureRandom.hex(3)}")
    message = AttachmentFixtures.deliver(request,
                                         [['records.txt', 'text/plain', text]])
    attachment = message.get_attachments_for_display.
      find { |a| a.filename == 'records.txt' }
    Disclosures::Creation.new(user: user,
                              attachment: attachment,
                              kind: 'released_records').create!.reload
  end

  def add_drafts(count)
    documents = Array.new(count) do |index|
      user = requesters[index % requesters.size]
      draft_for(user, "Gritting by ward\nNorth: #{index} runs\n")
    end
    documents.each do |document|
      document.log!('review_requested', user: document.requester)
    end
    documents
  end

  def uncached(path)
    sql = []
    callback = ->(*args) do
      event = args.last
      sql << event[:sql] unless event[:cached] || event[:name] == 'SCHEMA'
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      get path
    end
    expect(response).to have_http_status(:ok), path
    sql
  end

  it 'keeps the same statements for /admin, the drafts list and a public page as drafts are added' do
    add_drafts(4)
    sign_in(admin)
    paths = ['/admin', '/documents/review', '/help/about']
    paths.each { |path| get path }
    small = paths.to_h { |path| [path, uncached(path)] }

    add_drafts(8)
    large = paths.to_h { |path| [path, uncached(path)] }

    paths.each { |path| expect(large[path].size).to eq(small[path].size), path }
    expect(large['/help/about'].
             grep(/disclosure_documents|disclosure_pages|disclosure_events/)).
      to eq([])
    expect(response.body).not_to include('admin-bar__count')
  end

  it 'lists the same drafts on /admin and the drafts list' do
    add_drafts(3)
    sign_in(admin)
    get '/admin'
    rows = Nokogiri::HTML(response.body).
      css('.admin-rows li .admin-rows__title').map(&:text)
    get '/documents/review'
    expect(Nokogiri::HTML(response.body).
             css('.admin-rows li .admin-rows__title').map(&:text)).to eq(rows)
    expect(rows.size).to eq(3)
  end

  describe Disclosures::Checks do
    let(:page_class) { Struct.new(:text, :number, :label, :anchor) }

    def fake_document(user, texts)
      pages = texts.each_with_index.map do |text, index|
        page_class.new(
          text, index + 1, "Page #{index + 1}", "page-#{index + 1}"
        )
      end
      Struct.new(:requester, :pages).new(user, pages)
    end

    def every_page(document)
      needles = described_class.needles_for(document.requester)
      document.pages.flat_map do |page|
        text = described_class.even(page.text)
        needles.filter_map do |pattern, what|
          if text.match?(pattern)
            described_class::Hit.new(page: page.number,
                                     label: page.label,
                                     anchor: page.anchor,
                                     what: what)
          end
        end
      end
    end

    it 'finds the same hits when it skips pages that can’t name the requester' do
      cases = {
        'Rowan Requester' => ["Dear Rowan,\nThanks", "Rowan\n  Requester",
                              'Mr. Requester said', 'xRowan Requesterx',
                              "ʼRowan Requester", 'Rowan Requesterʼs file',
                              "HI ROWAN", 'Gritting by ward', '', nil],
        'Dr Ann O’Brien' => ['Dear Ann,', "Ms. O'Brien", 'O‘Brien', 'OʼBrien',
                             'Mrs O`Brien', 'OBrien', 'Dear Annie'],
        'Jo Li' => ['Hi Jo', 'Jo Li', 'Mx Li', 'JoLi', 'Hi Joanne'],
        'Mx Quinn' => ['Quinn', 'Dear Quinn', 'Quinnell', 'Mx. Quinn'],
        'Kaʼimi Example' => ["Ka'imi Example", 'Ka’imi', 'Dear Kaʼimi',
                             'Kaimi Example', 'Example’s']
      }
      total = 0
      cases.each do |name, texts|
        user = FactoryBot.build(:user, name: name)
        texts += ["Contact: #{user.email.upcase}", "x#{user.email}x"]
        expected = every_page(fake_document(user, texts))
        expect(described_class.personal(fake_document(user, texts))).
          to eq(expected), name
        total += expected.size
      end
      expect(total).to be > 25
    end

    it 'reads no page text it can rule out' do
      user = FactoryBot.build(:user, name: 'Rowan Requester')
      allow(described_class).to receive(:even).and_call_original
      expect(
        described_class.personal(fake_document(user,
                                               ['Gritting by ward',
                                                'Dear Rowan,']))
      ).to be_present
      expect(described_class).
        not_to have_received(:even).with('Gritting by ward')
      expect(described_class).to have_received(:even).with('Dear Rowan,')
    end
  end
end
