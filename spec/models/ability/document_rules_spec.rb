require 'spec_helper'

RSpec.describe Ability::DocumentRules do
  include ActiveJob::TestHelper
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user) }
  let(:other) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:attachment) do
    message = AttachmentFixtures.deliver(
      info_request,
      [['runs.txt', 'text/plain', "Gritting runs: 12\n"]]
    )
    message.get_attachments_for_display.
      find { |part| part.filename == 'runs.txt' }
  end
  let(:document) do
    Disclosures::Creation.new(user: owner, attachment: attachment,
                              kind: 'released_records').create!
  end

  def answers(record)
    { visitor: nil, requester: owner, other: other,
      admin: admin }.transform_values do |user|
      ability = Ability.new(user)
      [ability.can?(:admin, record), ability.can?(:read, record)]
    end
  end

  it 'answers for a document on a live request' do
    expect(answers(document)).to eq(
      visitor: [false, false], requester: [false, true], other: [false, false],
      admin: [true, true]
    )
  end

  it 'keeps the requester out of a document made from a part an admin hid' do
    document
    FoiAttachment.find(attachment.id).
      update!(prominence: 'hidden', prominence_reason: 'Synthetic')
    expect(answers(document.reload)).to eq(
      visitor: [false, false], requester: [false, false], other: [false, false],
      admin: [true, true]
    )
  end

  it 'answers for a document kept after its request was deleted' do
    document.update_columns(request_deleted_at: Time.current,
                            owner_id: owner.id,
                            info_request_id: nil,
                            incoming_message_id: nil,
                            foi_attachment_id: nil)
    expect(answers(document.reload)).to eq(
      visitor: [false, false], requester: [false, true], other: [false, false],
      admin: [true, true]
    )
  end

  it "keeps the requester out when the document's own request is hidden, " \
     'wherever its file has moved' do
    document.update_columns(state: 'published')
    elsewhere = FactoryBot.create(:info_request, user: owner)
    IncomingMessage.where(id: attachment.incoming_message_id).
      update_all(info_request_id: elsewhere.id)
    InfoRequest.where(id: info_request.id).update_all(prominence: 'hidden')
    owner.update!(ban_text: 'Synthetic ban')
    expect(Ability.new(owner).can?(:withdraw_document, document.reload)).
      to be(false)
  end

  it 'lets a banned requester read their document, and a banned admin nothing' do
    document
    owner.update!(ban_text: 'Synthetic ban')
    admin.update!(ban_text: 'Synthetic ban')
    expect(answers(document.reload)).to include(requester: [false, true],
                                                admin: [false, false])
  end

  context 'with requester editing enabled' do
    around do |example|
      with_setting(Disclosures, :requester_editing, true) { example.run }
    end

    it 'lets a banned requester withdraw publication, but not edit or publish' do
      document.update_columns(state: 'published')
      owner.update!(ban_text: 'Synthetic ban')
      ability = Ability.new(owner)
      expect(ability.can?(:withdraw_document, document)).to be(true)
      expect(ability.can?(:edit_document, document)).to be(false)
      expect(ability.can?(:publish_own_document, document)).to be(false)
    end

    it 'does not give a closed requester the withdrawal exception' do
      document.update_columns(state: 'published')
      owner.update!(closed_at: Time.current)
      ability = Ability.new(owner)
      expect(ability.can?(:withdraw_document, document)).to be(false)
    end

    %i[masking_failed_at erased_at].each do |attribute|
      it "blocks creating a document from a source with #{attribute}, including for admins" do
        expect(Ability.new(admin).can?(:create_document, attachment)).
          to be(true)
        attachment.update_columns(attribute => Time.current)
        expect(Ability.new(admin).can?(:create_document, attachment)).
          to be(false)
        expect(Ability.new(owner).can?(:create_document, attachment)).
          to be(false)
      end
    end

    it 'allows admin changes after request deletion only for a previously public document' do
      document.update_columns(request_deleted_at: Time.current,
                              owner_id: owner.id,
                              info_request_id: nil,
                              incoming_message_id: nil,
                              foi_attachment_id: nil)
      expect(Ability.new(admin).can?(:publish_document, document)).to be(false)
      expect(Ability.new(owner).can?(:publish_own_document, document)).
        to be(false)
      document.update_columns(first_published_at: Time.current)
      expect(Ability.new(admin).can?(:publish_document, document)).to be(true)
      expect(Ability.new(admin).can?(:change_document_file, document)).
        to be(true)
      expect(Ability.new(owner).can?(:edit_document, document)).to be(false)
    end
  end

  it 'has no :manage or :all rule that could widen or narrow either action' do
    document
    checked_actions = %i[admin read]
    [nil, owner, other, admin].each do |user|
      permissions = Ability.new(user).permissions
      managed = permissions.values.flat_map do |actions|
        actions.fetch(:manage, {}).keys
      end
      expect(managed).not_to include('all', 'Disclosures::Document')
      checked_actions.each do |action|
        expect(permissions[:can].fetch(action, {}).keys).not_to include('all')
        expect(permissions[:cannot].fetch(action, {}).keys).to be_empty
      end
      expect(permissions[:can]).not_to have_key(:read_as_requester)
    end
  end
end
