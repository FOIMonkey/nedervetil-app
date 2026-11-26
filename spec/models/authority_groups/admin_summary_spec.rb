require 'spec_helper'

RSpec.describe AuthorityGroups::AdminSummary do
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:body) do
    FactoryBot.create(:public_body,
                      tag_string: 'south_east police gss:E07000901 misc')
  end
  let(:summary) { described_class.new(body) }

  def heading(title)
    Category.create!(title: title, description: '',
                     parent_ids: [PublicBody.category_root.id])
  end

  def group(heading, title, tag)
    Category.create!(title: title, description: '', category_tag: tag,
                     parent_ids: [heading.id])
  end

  def request_to(body, **attributes)
    FactoryBot.create(:info_request, public_body: body, user: owner,
                                     **attributes)
  end

  def published_document(request, name)
    publish(delivered_document(request, name, 'text/plain',
                               "Gritting by ward\nNorth: 12 runs\n",
                               by: owner, ready: false),
            by: admin)
  end

  def release(title, released_on, **attributes)
    AuthorityGroups::ExternalRelease.create!(
      public_body: body, title: title, released_on: released_on,
      url: "https://log.example.invalid/#{title.parameterize}", **attributes
    )
  end

  describe 'its tags' do
    before do
      group(heading('Place'), 'South East', 'south_east')
      type = heading('Type')
      group(type, 'Police forces', 'police')
      group(type, 'District councils', 'district_council')
      group(heading('Sector'), 'Health', 'health')
    end

    it 'sorts its groups under their headings, leaving out a heading with none' do
      titles = summary.groups.transform_values do |categories|
        categories.map(&:title)
      end
      expect(titles).
        to eq('place' => ['South East'], 'type' => ['Police forces'])
    end

    it 'reads its area codes from its gss: tags' do
      expect(summary.area_codes).to eq(['E07000901'])
    end

    it 'keeps the tags that are neither a group nor an area code apart' do
      expect(summary.other_tags.map(&:name)).to eq(['misc'])
    end
  end

  describe 'its requests' do
    it 'counts them, the hidden with the rest' do
      request_to(body)
      request_to(body, prominence: 'hidden')
      expect(summary.request_count).to eq(2)
    end
  end

  describe 'its published documents' do
    before { stub_const("#{described_class}::RECENT", 2) }

    it 'counts the listed ones and gives the newest few, not a draft' do
      request = request_to(body)
      names = %w[first.txt second.txt third.txt]
      documents = names.map { |name| published_document(request, name) }
      delivered_document(request, 'draft.txt', 'text/plain', "Draft\n",
                         by: owner, ready: false)
      expect(summary.document_count).to eq(3)
      expect(summary.more_documents?).to be(true)
      expect(summary.recent_documents.to_a).
        to eq([documents[2], documents[1]])
    end

    it 'has none to list for an authority with nothing published' do
      expect(summary.document_count).to eq(0)
      expect(summary.more_documents?).to be(false)
      expect(summary.recent_documents).to be_empty
    end
  end

  describe 'its external releases' do
    before { stub_const("#{described_class}::RECENT", 2) }

    it 'counts every one, hidden too, and gives the newest few' do
      release('Oldest', Date.new(2026, 9, 1))
      release('Newest', Date.new(2026, 9, 3), hidden_at: Time.zone.now)
      release('Middle', Date.new(2026, 9, 2))
      expect(summary.release_count).to eq(3)
      expect(summary.recent_releases.map(&:title)).to eq(%w[Newest Middle])
    end
  end

  describe 'what it holds' do
    let(:body) do
      FactoryBot.create(:public_body,
                        name: 'Ashdown District Council',
                        tag_string: 'local_council district_council england ' \
                                    'holds_not:food_hygiene')
    end

    it 'lists each thing its kind of authority holds once, with what an admin unticked' do
      skip 'Topics arrives in B12' unless defined?(Topics::Topic)
      keys = summary.holdings.map { |holder, _topic| holder.key }
      expect(keys).to include('bins_street', 'food_hygiene')
      expect(keys.uniq).to eq(keys)
      ticked = summary.holdings.to_h do |holder, _topic|
        [holder.key, summary.ticked?(holder)]
      end
      expect(ticked).to include('bins_street' => true, 'food_hygiene' => false)
    end
  end

  describe 'its line on group pages' do
    let(:body) do
      FactoryBot.create(:public_body, name: 'Caledon Police',
                                      tag_string: 'police scotland')
    end

    it 'finds the holders that name it, and the words they give by default' do
      skip 'Topics arrives in B12' unless defined?(Topics::Topic)
      expect(summary.named_holders.map(&:who)).to eq(['Caledon Police'])
      expect(summary.default_who_line).to start_with('Crime, stop and search')
    end

    it 'gives an admin’s own line once one is saved' do
      expect(summary.who_line).to be_nil
      AuthorityGroups::WhoLine.save_for(body, 'Crime across Scotland')
      expect(summary.who_line).to eq('Crime across Scotland')
    end

    it 'finds no holders for an authority the topic files don’t name' do
      other = FactoryBot.create(:public_body, name: 'Northmoor Council')
      expect(described_class.new(other).named_holders).to be_empty
    end
  end
end
