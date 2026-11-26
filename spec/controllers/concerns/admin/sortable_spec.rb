require 'spec_helper'

RSpec.describe Admin::Sortable do
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include Admin::Sortable
    end
  end

  let(:controller) { controller_class.new }

  describe '#sorted' do
    # Three accounts changed at the same moment, which the chosen column
    # can't tell apart, and one changed later.
    let(:tied) do
      FactoryBot.create_list(:user, 3).each do |user|
        user.update_columns(updated_at: Time.zone.local(2026, 3, 1, 9))
      end
    end

    let(:later) do
      FactoryBot.create(:user).tap do |user|
        user.update_columns(updated_at: Time.zone.local(2026, 3, 2, 9))
      end
    end

    let(:relation) { User.where(id: tied + [later]) }

    def sorted_ids(sort_query)
      allow(controller).to receive(:sort_query).and_return(sort_query)
      controller.sorted(relation).ids
    end

    it 'sorts by the chosen column first' do
      expect(sorted_ids('updated_at DESC').first).to eq(later.id)
      expect(sorted_ids('updated_at ASC').last).to eq(later.id)
    end

    it 'puts rows that tie in id order when sorting upwards' do
      expect(sorted_ids('updated_at ASC').first(3)).
        to eq(tied.map(&:id).sort)
    end

    it 'puts rows that tie highest id first when sorting downwards' do
      expect(sorted_ids('updated_at DESC').last(3)).
        to eq(tied.map(&:id).sort.reverse)
    end

    it 'replaces an order the list already had' do
      allow(controller).to receive(:sort_query).and_return('updated_at ASC')
      listed = controller.sorted(relation.order(id: :desc)).ids

      expect(listed).to eq(tied.map(&:id).sort + [later.id])
    end

    it 'leaves a list sorted by relevance as it is' do
      allow(controller).to receive(:sort_query).and_return(nil)
      ranked = relation.order(id: :desc)

      expect(controller.sorted(ranked).to_sql).to eq(ranked.to_sql)
    end
  end
end
