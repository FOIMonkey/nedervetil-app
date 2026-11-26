require 'spec_helper'
require 'alaveteli_features/feature'
require_relative 'mocks/user'
require_relative 'mocks/role'

RSpec.describe AlaveteliFeatures::Feature::CollectionMethods do
  let(:base_collection) do
    AlaveteliFeatures::Collection.new(AlaveteliFeatures::Feature)
  end

  let(:actor) { MockUser.new(1, [guest_role]) }
  let!(:feature_1) { base_collection.add(:feature_1) }
  let!(:feature_2) { base_collection.add(:feature_2) }

  let(:admin_role) { MockRole.new(:admin) }
  let(:guest_role) { MockRole.new(:guest) }
  let!(:admin_feature) { base_collection.add(:admin_feature) }
  let!(:guest_feature) { base_collection.add(:guest_feature) }

  before do
    AlaveteliFeatures.backend.enable_actor(:feature_1, actor)
    admin_feature.roles << admin_role
    guest_feature.roles << guest_role
  end

  describe '#with_actor' do
    it 'returns a collection with independently bound features' do
      bound = base_collection.with_actor(actor)

      expect(bound).not_to equal(base_collection)
      expect(bound.actor).to equal(actor)
      expect(bound.first.actor).to equal(actor)
      expect(bound.first).not_to equal(feature_1)
      expect(base_collection.actor).to be_nil
      expect(feature_1.actor).to be_nil
    end

    it 'keeps actors separate across concurrent callers' do
      other_actor = MockUser.new(2, [admin_role])
      ready = Queue.new
      release = Queue.new
      threads = [actor, other_actor].map do |current_actor|
        Thread.new do
          bound = base_collection.with_actor(current_actor)
          ready << true
          release.pop
          [bound.actor, bound.map(&:actor)]
        end
      end

      2.times { ready.pop }
      2.times { release << true }
      expected = [
        [actor, Array.new(base_collection.count, actor)],
        [other_actor, Array.new(base_collection.count, other_actor)]
      ]
      expect(threads.map(&:value)).to eq(expected)
      expect(base_collection.actor).to be_nil
      expect(base_collection.map(&:actor)).to all(be_nil)
    end
  end

  describe '#enabled?' do
    context 'without actor' do
      it 'raises ActorNotDefinedError' do
        expect { base_collection.enabled?(:feature_1) }.to raise_error(
          AlaveteliFeatures::Feature::ActorNotDefinedError
        )
      end
    end

    context 'with actor' do
      let(:collection) { base_collection.with_actor(actor) }

      it 'returns true is feature is enabled' do
        expect(collection.enabled?(:feature_1)).to eq(true)
      end

      it 'returns false is feature is disabled' do
        expect(collection.enabled?(:feature_2)).to eq(false)
      end
    end
  end

  describe '#assign_features' do
    context 'without actor' do
      it 'raises ActorNotDefinedError' do
        expect { base_collection.assign_features([:feature_2]) }.to raise_error(
          AlaveteliFeatures::Feature::ActorNotDefinedError
        )
      end
    end

    context 'with actor' do
      let(:collection) { base_collection.with_actor(actor) }

      it 'enabled features' do
        expect { collection.assign_features([:feature_2]) }.to \
          change { collection.enabled?(:feature_2) }.from(false).to(true)
      end

      it 'disable other features' do
        AlaveteliFeatures.backend.enable_actor(:feature_1, actor)
        expect { collection.assign_features([:feature_2]) }.to \
          change { collection.enabled?(:feature_1) }.from(true).to(false)
      end
    end
  end

  describe '#assign_role_features' do
    context 'without actor' do
      it 'raises ActorNotDefinedError' do
        expect { base_collection.assign_role_features }.to raise_error(
          AlaveteliFeatures::Feature::ActorNotDefinedError
        )
      end
    end

    context 'with actor' do
      let(:collection) { base_collection.with_actor(actor) }

      it 'enabled features if the actor has the correct role' do
        expect { collection.assign_role_features }.to \
          change { collection.enabled?(:guest_feature) }.from(false).to(true)
      end

      it 'disable features if the actor does not have to correct role' do
        AlaveteliFeatures.backend.enable_actor(:admin_feature, actor)
        expect { collection.assign_role_features }.to \
          change { collection.enabled?(:admin_feature) }.from(true).to(false)
      end
    end
  end
end
