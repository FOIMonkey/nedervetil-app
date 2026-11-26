require 'spec_helper'
require "cancan/matchers"

# Requests have no normal prominence; messages have no requester_only.
RSpec.shared_examples_for "a class with message prominence" do |options = {}|
  normal = options.fetch(:normal, true)
  requester_only = options.fetch(:requester_only, true)

  context 'if the prominence is hidden' do
    let(:prominence) { 'hidden' }

    it 'should return true for an admin user' do
      expect(admin_ability).to be_able_to(:read, resource)
    end

    it 'should return false for a non-admin user' do
      expect(other_user_ability).not_to be_able_to(:read, resource)
    end

    it 'should return false for the owner' do
      expect(owner_ability).not_to be_able_to(:read, resource)
    end
  end

  if requester_only
    context 'if the prominence is requester_only' do
      let(:prominence) { 'requester_only' }

      it 'should return true if the user owns the right resource' do
        expect(owner_ability).to be_able_to(:read, resource)
      end

      it 'should return true for an admin user' do
        expect(admin_ability).to be_able_to(:read, resource)
      end

      it 'should return false if the user does not own the right resource' do
        expect(other_user_ability).not_to be_able_to(:read, resource)
      end
    end
  end

  next unless normal

  context 'if the prominence is normal' do
    let(:prominence) { 'normal' }

    it 'should return false for a non-admin user' do
      expect(other_user_ability).not_to be_able_to(:read, resource)
    end

    it 'should return true for an admin user' do
      expect(admin_ability).to be_able_to(:read, resource)
    end

    it 'should return true if the user owns the right resource' do
      expect(owner_ability).to be_able_to(:read, resource)
    end
  end
end

RSpec.describe Ability do
  let(:pro_ability) { Ability.new(FactoryBot.create(:pro_user)) }
  let(:admin_ability) { Ability.new(FactoryBot.create(:admin_user)) }
  let(:other_user_ability) { Ability.new(FactoryBot.create(:user)) }
  let(:guest_ability) { Ability.guest }

  describe '.guest' do
    it 'returns Ability instance with no user' do
      guest = Ability.guest
      expect(guest).to be_an(Ability)
      expect(guest.user).to eq nil
    end
  end

  describe "reading FoiAttachment" do
    let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
    let(:incoming_message) { info_request.incoming_messages.first }
    let!(:resource) { incoming_message.foi_attachments.first }
    let!(:owner_ability) { Ability.new(info_request.user) }

    before do
      resource.update(prominence: prominence)
    end

    it_behaves_like "a class with message prominence", normal: false

    context 'when resource is readable but incoming message is not' do
      let(:prominence) { 'requester_only' }

      before do
        allow(owner_ability).to receive(:can?).and_call_original
        allow(owner_ability).to receive(:can?).with(:read, incoming_message).
          and_return(false)
      end

      it { expect(owner_ability).not_to be_able_to(:read, resource) }
    end

    context 'when resource is readable but info request is not' do
      let(:prominence) { 'requester_only' }

      before do
        allow(owner_ability).to receive(:can?).and_call_original
        allow(owner_ability).to receive(:can?).with(:read, info_request).
          and_return(false)
      end

      it { expect(owner_ability).not_to be_able_to(:read, resource) }
    end

    context 'when attachment is erased' do
      let(:prominence) { 'requester_only' }
      let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
      let(:incoming_message) { info_request.incoming_messages.first }
      let(:resource) do
        FactoryBot.create(:body_text,
                          incoming_message: incoming_message,
                          erased_at: Time.zone.now)
      end
      let(:owner_ability) { Ability.new(info_request.user) }

      it 'prevents reading' do
        expect(owner_ability).not_to be_able_to(:read, resource)
      end
    end
  end

  describe "reading IncomingMessages" do
    let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
    let!(:resource) { info_request.incoming_messages.first }
    let!(:owner_ability) { Ability.new(info_request.user) }

    before do
      resource.update(prominence: prominence)
    end

    it_behaves_like "a class with message prominence", requester_only: false

    context 'when resource is readable but info request is not' do
      let(:prominence) { 'normal' }

      before do
        allow(owner_ability).to receive(:can?).and_call_original
        allow(owner_ability).to receive(:can?).with(:read, info_request).
          and_return(false)
      end

      it { expect(owner_ability).not_to be_able_to(:read, resource) }
    end
  end

  describe 'managing OutgoingMessage::Snippet' do
    subject { ability }

    let(:ability) { Ability.new(user) }
    let(:snippet) { FactoryBot.create(:outgoing_message_snippet) }

    context 'when the user is an admin' do
      let(:user) { FactoryBot.create(:user, :admin) }
      it { is_expected.to be_able_to(:manage, snippet) }
    end

    context 'when the user is a normal user' do
      let(:user) { FactoryBot.build(:user) }
      it { is_expected.not_to be_able_to(:manage, snippet) }
    end
  end

  describe "reading OutgoingMessages" do
    let(:info_request) { FactoryBot.create(:info_request) }
    let!(:resource) { info_request.outgoing_messages.first }
    let!(:owner_ability) { Ability.new(info_request.user) }

    before do
      resource.update(prominence: prominence)
    end

    it_behaves_like "a class with message prominence", requester_only: false

    context 'when resource is readable but info request is not' do
      let(:prominence) { 'normal' }

      before do
        allow(owner_ability).to receive(:can?).and_call_original
        allow(owner_ability).to receive(:can?).with(:read, info_request).
          and_return(false)
      end

      it { expect(owner_ability).not_to be_able_to(:read, resource) }
    end
  end

  describe "reading InfoRequests" do
    let!(:resource) { FactoryBot.create(:info_request, prominence: prominence) }
    let!(:owner_ability) { Ability.new(resource.user) }

    it_behaves_like "a class with message prominence", normal: false

    context 'when the request belongs to a pro user' do
      let!(:resource) do
        FactoryBot.create(:info_request, prominence: prominence,
                                         user: FactoryBot.create(:pro_user))
      end

      %w[hidden requester_only].each do |prominence_value|
        context "if the prominence is #{prominence_value}" do
          let(:prominence) { prominence_value }

          it 'should return false for a pro user who does not own it' do
            with_feature_enabled(:alaveteli_pro) do
              expect(pro_ability).not_to be_able_to(:read, resource)
            end
          end

          it 'should return false for a non-admin user' do
            expect(other_user_ability).not_to be_able_to(:read, resource)
          end

          it 'should return false for a guest' do
            expect(guest_ability).not_to be_able_to(:read, resource)
          end

          it 'should only let the owner read it unless it is hidden' do
            with_feature_enabled(:alaveteli_pro) do
              if prominence == 'hidden'
                expect(owner_ability).not_to be_able_to(:read, resource)
              else
                expect(owner_ability).to be_able_to(:read, resource)
              end
            end
          end
        end
      end
    end
  end

  describe "updating request state of InfoRequests" do
    context "given an old and unclassified request" do
      let(:request) { FactoryBot.create(:old_unclassified_request) }

      context "when logged out" do
        let(:ability) { Ability.guest }

        it "should return false" do
          expect(ability).not_to be_able_to(:update_request_state, request)
        end
      end

      # Requests are private: nobody else classifies one, however old.
      context "when logged in but not owner of request" do
        let(:user) { FactoryBot.create(:user) }
        let(:ability) { Ability.new(user) }

        it "should return false" do
          expect(ability).not_to be_able_to(:update_request_state, request)
        end
      end

      context "when owner of request" do
        let(:user) { request.user }
        let(:ability) { Ability.new(user) }

        it "should return true" do
          expect(ability).to be_able_to(:update_request_state, request)
        end
      end
    end

    context "given a new request" do
      let(:request) { FactoryBot.create(:info_request) }

      context "when logged out" do
        let(:ability) { Ability.guest }

        it "should return false" do
          expect(ability).not_to be_able_to(:update_request_state, request)
        end
      end

      context "when logged in" do
        context "as owner of request" do
          let(:ability) { Ability.new(request.user) }

          it "should return true" do
            expect(ability).to be_able_to(:update_request_state, request)
          end
        end

        context "as an admin" do
          let(:ability) { Ability.new(FactoryBot.create(:admin_user)) }

          it "should return true" do
            expect(ability).to be_able_to(:update_request_state, request)
          end
        end

        context "but not owner of request" do
          let(:ability) { Ability.new(FactoryBot.create(:user)) }

          it "should return false" do
            expect(ability).not_to be_able_to(:update_request_state, request)
          end
        end

        context "as the owner, on a suspended account" do
          let(:ability) do
            Ability.new(request.user.tap { _1.update!(ban_text: 'Banned') })
          end

          it "should return false" do
            expect(ability).not_to be_able_to(:update_request_state, request)
          end
        end
      end
    end
  end

  describe "reading InfoRequestBatches" do
    let(:admin_ability) { Ability.new(FactoryBot.create(:admin_user)) }
    let(:pro_user_ability) { Ability.new(FactoryBot.create(:pro_user)) }
    let(:other_user_ability) { Ability.new(FactoryBot.create(:user)) }

    context "when the batch belongs to a pro user" do
      let(:resource) do
        FactoryBot.create(:info_request_batch,
                          user: FactoryBot.create(:pro_user))
      end

      context "when the user owns the batch" do
        let(:ability) { Ability.new(resource.user) }

        it "should return true" do
          with_feature_enabled(:alaveteli_pro) do
            expect(ability).to be_able_to(:read, resource)
          end
        end
      end

      context "when the user is an admin" do
        it "should return true" do
          with_feature_enabled(:alaveteli_pro) do
            expect(admin_ability).to be_able_to(:read, resource)
          end
        end
      end

      context "when the user is a pro but doesn't own the batch" do
        it "should return false" do
          with_feature_enabled(:alaveteli_pro) do
            expect(pro_user_ability).not_to be_able_to(:read, resource)
          end
        end
      end

      context "when the user is a normal user" do
        it "should return false" do
          with_feature_enabled(:alaveteli_pro) do
            expect(other_user_ability).not_to be_able_to(:read, resource)
          end
        end
      end

      context "when logged out" do
        it "should return false" do
          with_feature_enabled(:alaveteli_pro) do
            expect(Ability.guest).not_to be_able_to(:read, resource)
          end
        end
      end
    end

    context "when the batch belongs to a normal user" do
      let(:resource) { FactoryBot.create(:info_request_batch) }
      let(:reader_abilities) do
        [
          admin_ability,
          Ability.new(resource.user)
        ]
      end
      let(:other_abilities) do
        [
          pro_user_ability,
          other_user_ability,
          Ability.guest
        ]
      end

      it "should return true only for the owner and admins" do
        reader_abilities.each do |ability|
          expect(ability).to be_able_to(:read, resource)
        end
        other_abilities.each do |ability|
          expect(ability).not_to be_able_to(:read, resource)
        end
      end
    end
  end

  describe "updating InfoRequestBatches" do
    let(:admin_ability) { Ability.new(FactoryBot.create(:admin_user)) }
    let(:pro_user_ability) { Ability.new(FactoryBot.create(:pro_user)) }
    let(:other_user_ability) { Ability.new(FactoryBot.create(:user)) }

    context "when the batch belongs to a pro user" do
      let(:resource) do
        FactoryBot.create(:info_request_batch,
                          user: FactoryBot.create(:pro_user))
      end

      context "when the user owns the batch" do
        it 'allows pro users to update the batch' do
          ability = Ability.new(resource.user)
          with_feature_enabled(:alaveteli_pro) do
            expect(ability).to be_able_to(:update, resource)
          end
        end
      end

      context "when the user is an admin" do
        it "should return true" do
          with_feature_enabled(:alaveteli_pro) do
            expect(admin_ability).to be_able_to(:update, resource)
          end
        end
      end

      context "when the user is a pro but doesn't own the batch" do
        it "should return false" do
          with_feature_enabled(:alaveteli_pro) do
            expect(pro_user_ability).not_to be_able_to(:update, resource)
          end
        end
      end

      context "when the user is a normal user" do
        it "should return false" do
          with_feature_enabled(:alaveteli_pro) do
            expect(other_user_ability).not_to be_able_to(:update, resource)
          end
        end
      end

      context "when logged out" do
        it "should return false" do
          with_feature_enabled(:alaveteli_pro) do
            expect(Ability.guest).not_to be_able_to(:update, resource)
          end
        end
      end
    end

    context "when the batch belongs to a normal user" do
      let(:resource) { FactoryBot.create(:info_request_batch) }

      context "when the user owns the batch" do
        let(:ability) { Ability.new(resource.user) }

        it "should return true" do
          with_feature_enabled(:alaveteli_pro) do
            expect(ability).to be_able_to(:update, resource)
          end
        end
      end

      context "when the user is an admin" do
        it "should return true" do
          with_feature_enabled(:alaveteli_pro) do
            expect(admin_ability).to be_able_to(:update, resource)
          end
        end
      end

      context "when the user is a pro but doesn't own the batch" do
        it "should return false" do
          with_feature_enabled(:alaveteli_pro) do
            expect(pro_user_ability).not_to be_able_to(:update, resource)
          end
        end
      end

      context "when the user is a normal user" do
        it "should return false" do
          with_feature_enabled(:alaveteli_pro) do
            expect(other_user_ability).not_to be_able_to(:update, resource)
          end
        end
      end
    end
  end

  describe "accessing the inbox (:alaveteli_pro)" do
    subject(:ability) { Ability.new(user) }

    context "when an account is signed in" do
      let(:user) { FactoryBot.create(:user) }

      it { is_expected.to be_able_to(:access, :alaveteli_pro) }
    end

    context "when the account is an admin" do
      let(:user) { FactoryBot.create(:admin_user) }

      it { is_expected.to be_able_to(:access, :alaveteli_pro) }
    end

    context "when nobody is signed in" do
      let(:user) { nil }

      it { is_expected.not_to be_able_to(:access, :alaveteli_pro) }
    end
  end

  describe "Logging in as a user" do
    let(:user) { FactoryBot.create(:user) }
    let(:other_user) { FactoryBot.create(:user) }
    let(:admin_user) { FactoryBot.create(:admin_user) }
    let(:other_admin) { FactoryBot.create(:admin_user) }

    it 'allows an admin to log in as an account' do
      expect(Ability.new(admin_user)).to be_able_to(:login_as, user)
    end

    it 'allows an admin to log in as another admin' do
      expect(Ability.new(admin_user)).to be_able_to(:login_as, other_admin)
    end

    it 'does not allow an admin to log in as a closed account' do
      user.close!
      expect(Ability.new(admin_user)).not_to be_able_to(:login_as, user)
    end

    it 'does not allow an admin to log in as themselves' do
      expect(Ability.new(admin_user)).not_to be_able_to(:login_as, admin_user)
    end

    it 'does not allow a suspended admin to log in as anyone' do
      admin_user.update!(ban_text: 'Suspended')
      expect(Ability.new(admin_user)).not_to be_able_to(:login_as, user)
    end

    it 'does not allow an account that is not an admin to log in as anyone' do
      expect(Ability.new(other_user)).not_to be_able_to(:login_as, user)
      expect(Ability.new(other_user)).not_to be_able_to(:login_as, admin_user)
    end
  end

  describe 'using the admin area (:access, :admin)' do
    it 'allows an admin' do
      expect(admin_ability).to be_able_to(:access, :admin)
    end

    it 'does not allow a suspended admin' do
      admin = FactoryBot.create(:admin_user, ban_text: 'Suspended')
      expect(Ability.new(admin)).not_to be_able_to(:access, :admin)
    end

    it 'does not allow an account that is not an admin, or nobody' do
      expect(other_user_ability).not_to be_able_to(:access, :admin)
      expect(guest_ability).not_to be_able_to(:access, :admin)
    end
  end

  describe 'seeing hidden authority groups (:admin, Group)' do
    it 'allows an admin and nobody else' do
      group = AuthorityGroups::Group
      expect(admin_ability).to be_able_to(:admin, group)
      expect(other_user_ability).not_to be_able_to(:admin, group)
      expect(guest_ability).not_to be_able_to(:admin, group)
    end
  end

  describe "reading an account's page (:read, User)" do
    let(:user) { FactoryBot.create(:user) }

    it 'allows its own active account' do
      expect(Ability.new(user)).to be_able_to(:read, user)
    end

    it 'does not allow its own account once suspended' do
      user.update!(ban_text: 'Suspended')
      expect(Ability.new(user)).not_to be_able_to(:read, user)
    end

    it 'allows an admin' do
      expect(admin_ability).to be_able_to(:read, user)
    end

    it 'does not allow another account, or nobody' do
      expect(other_user_ability).not_to be_able_to(:read, user)
      expect(guest_ability).not_to be_able_to(:read, user)
    end
  end

  describe 'adjusting deadlines (:adjust_deadlines)' do
    let(:request) { FactoryBot.create(:info_request) }

    it 'allows the requester and an admin' do
      expect(Ability.new(request.user)).
        to be_able_to(:adjust_deadlines, request)
      expect(admin_ability).to be_able_to(:adjust_deadlines, request)
    end

    it 'does not allow a suspended requester' do
      request.user.update!(ban_text: 'Suspended')
      expect(Ability.new(request.user)).
        not_to be_able_to(:adjust_deadlines, request)
    end

    it 'does not allow the requester of a hidden request' do
      request.update!(prominence: 'hidden')
      expect(Ability.new(request.user)).
        not_to be_able_to(:adjust_deadlines, request)
      expect(admin_ability).to be_able_to(:adjust_deadlines, request)
    end

    it 'does not allow another account, or nobody' do
      expect(other_user_ability).not_to be_able_to(:adjust_deadlines, request)
      expect(guest_ability).not_to be_able_to(:adjust_deadlines, request)
    end
  end

  describe 'creating a batch (:create, InfoRequestBatch)' do
    let(:user) { FactoryBot.create(:user) }

    it 'allows an active account when the permission is not required' do
      expect(Ability.new(user)).to be_able_to(:create, InfoRequestBatch)
    end

    it 'allows only a trusted active account when it is required' do
      with_setting(RequestLimits, :enforced, true) do
        expect(Ability.new(user)).not_to be_able_to(:create, InfoRequestBatch)
        user.update!(trusted: true)
        expect(Ability.new(user)).to be_able_to(:create, InfoRequestBatch)
        user.update!(ban_text: 'Suspended')
        expect(Ability.new(user)).not_to be_able_to(:create, InfoRequestBatch)
      end
    end

    it 'does not allow nobody' do
      expect(guest_ability).not_to be_able_to(:create, InfoRequestBatch)
    end
  end

  describe 'administering requests' do
    let(:user) { FactoryBot.create(:user) }
    let(:pro_user) { FactoryBot.create(:pro_user) }
    let(:admin_user) { FactoryBot.create(:admin_user) }

    context 'for a private request' do
      let(:info_request) { FactoryBot.create(:info_request) }

      it 'does allow an admin to administer' do
        with_feature_enabled(:alaveteli_pro) do
          ability = Ability.new(admin_user)
          expect(ability).to be_able_to(:admin, info_request)
        end
      end

      it 'does not allow a pro user to administer' do
        with_feature_enabled(:alaveteli_pro) do
          ability = Ability.new(pro_user)
          expect(ability).not_to be_able_to(:admin, info_request)
        end
      end

      it 'does not allow a user with no roles to administer' do
        with_feature_enabled(:alaveteli_pro) do
          ability = Ability.new(user)
          expect(ability).not_to be_able_to(:admin, info_request)
        end
      end

      it 'does not allow no user to administer' do
        with_feature_enabled(:alaveteli_pro) do
          ability = Ability.guest
          expect(ability).not_to be_able_to(:admin, info_request)
        end
      end
    end
  end

  describe 'administering InfoRequestBatch' do
    let(:user) { FactoryBot.create(:user) }
    let(:pro_user) { FactoryBot.create(:pro_user) }
    let(:admin_user) { FactoryBot.create(:admin_user) }

    context 'for a batch' do
      let(:batch) { FactoryBot.create(:info_request_batch) }

      it 'does allow an admin to administer' do
        with_feature_enabled(:alaveteli_pro) do
          ability = Ability.new(admin_user)
          expect(ability).to be_able_to(:admin, batch)
        end
      end

      it 'does not allow a pro user to administer' do
        with_feature_enabled(:alaveteli_pro) do
          ability = Ability.new(pro_user)
          expect(ability).not_to be_able_to(:admin, batch)
        end
      end

      it 'does not allow a user with no roles to administer' do
        with_feature_enabled(:alaveteli_pro) do
          ability = Ability.new(user)
          expect(ability).not_to be_able_to(:admin, batch)
        end
      end

      it 'does not allow no user to administer' do
        with_feature_enabled(:alaveteli_pro) do
          ability = Ability.guest
          expect(ability).not_to be_able_to(:admin, batch)
        end
      end
    end
  end
end
