require 'spec_helper'

RSpec.describe Topics::Holds do
  describe '.for_group' do
    let(:districts) do
      { 'tag' => 'district_council', 'label' => 'District councils' }
    end
    let(:fire) { { 'tag' => 'fire_authority', 'label' => 'Fire authorities' } }
    let(:waste_name) { 'Northshire Waste Authority' }

    let(:topics) do
      [topic('bins', [
               { 'what' => 'Bins, recycling', 'groups' => [districts] },
               { 'what' => 'Waste disposal', 'to' => { 'body' => waste_name } },
               { 'what' => 'Fire safety', 'groups' => [fire] },
               { 'what' => 'Ports', 'to' => { 'body' => 'Elsewhere Port' } }
             ]),
       topic('roads', [
               { 'what' => 'Planning', 'groups' => [fire, districts] },
               { 'what' => 'Bins, recycling', 'groups' => [districts] },
               { 'what' => 'Street works', 'groups' => [districts],
                 'to' => { 'body' => waste_name } },
               { 'what' => 'Lochs', 'groups' => [districts],
                 'nations' => ['scotland'] }
             ])]
    end

    let!(:district) do
      FactoryBot.create(:public_body, name: 'Southby District Council',
                                      tag_string: 'district_council')
    end
    let!(:waste) do
      FactoryBot.create(:public_body, name: waste_name, tag_string: 'waste')
    end

    before { allow(Topics::Topic).to receive(:all).and_return(topics) }

    def topic(slug, holders)
      Topics::Topic.new(slug, 'title' => slug.titleize,
                              'summary' => "#{slug} records", 'order' => 1,
                              'holders' => holders)
    end

    def selects(&block)
      queries = []
      listener = ->(*, payload) { queries << payload[:sql] }
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(listener, 'sql.active_record',
                                                &block)
      end
      queries.grep(/\A\s*(SELECT|WITH)\b/i)
    end

    it 'lists what members hold by kind and by name, busiest first' do
      expect(described_class.for_group([district.id, waste.id], 'england')).
        to eq([['District councils', 'district_council',
                ['Bins, recycling', 'Planning', 'Street works']],
               [waste_name, waste, ['Waste disposal']]])
    end

    it 'counts every nation’s holders when no nation is given' do
      expect(described_class.for_group([district.id], nil)).
        to eq([['District councils', 'district_council',
                ['Bins, recycling', 'Planning', 'Street works', 'Lochs']]])
    end

    it 'leaves out holders that only name an authority outside the group' do
      expect(described_class.for_group([district.id], 'england')).
        to eq([['District councils', 'district_council',
                ['Bins, recycling', 'Planning', 'Street works']]])
    end

    it 'orders rows with as many things by their label' do
      allow(Topics::Topic).to receive(:all).and_return(
        [topic('bins', [
                 { 'what' => 'Waste disposal',
                   'to' => { 'body' => waste_name } },
                 { 'what' => 'Bins', 'groups' => [districts] }
               ])]
      )

      expect(described_class.for_group([waste.id, district.id], 'england').
        map(&:first)).to eq(['District councils', waste_name])
    end

    it 'lists nothing for a group whose members hold nothing' do
      other = FactoryBot.create(:public_body, tag_string: 'museum')

      expect(described_class.for_group([other.id], 'england')).to eq([])
    end

    it 'reads the database twice for members of a kind, however many' do
      more = Array.new(4) do |index|
        FactoryBot.create(:public_body, name: "Member #{index}",
                                        tag_string: 'district_council')
      end

      one = selects { described_class.for_group([district.id], 'england') }
      five = selects do
        described_class.for_group([district.id, *more.map(&:id)], 'england')
      end

      expect(one.size).to eq(2)
      expect(five.size).to eq(2)
    end

    it 'reads a named member’s translation once more' do
      ids = [district.id, waste.id]

      expect(selects { described_class.for_group(ids, 'england') }.size).
        to eq(3)
    end
  end
end
