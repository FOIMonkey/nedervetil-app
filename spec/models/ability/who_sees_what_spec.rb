require 'spec_helper'

RSpec.describe 'Who may see what' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  def self.roles
    { visitor: 'visitor', other: 'another account', requester: 'requester',
      admin: 'admin' }
  end

  def self.seen_by(*roles)
    self.roles.keys.index_with { |role| roles.include?(role) }
  end

  def self.everyone
    seen_by(*roles.keys)
  end

  def self.who(row)
    names = row.select { |_role, seen| seen }.keys.map { roles[_1] }
    names.empty? ? 'nobody' : names.join(', ')
  end

  delegate :seen_by, :everyone, to: :class

  let(:requester) { FactoryBot.create(:user) }
  let(:other) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }

  let(:redacted_runs) { "Gritting runs: [redacted]\n" }

  # Pin defaults so test config overrides do not change results.
  around do |example|
    with_setting(Disclosures, :requester_editing, true) do
      with_setting(AttachmentManagement, :requester_access, 'redact') do
        example.run
      end
    end
  end

  def expect_document_row(document, row)
    expect(document_answers(document)).to eq(row)
  end

  def answers(record, action = :read)
    { visitor: nil, other: other, requester: requester, admin: admin }.
      transform_values { |user| Ability.new(user).can?(action, record) }
  end

  def document_answers(document)
    %i[read admin].index_with do |action|
      answers(document, action)
    end
  end

  def new_request(prominence: 'requester_only')
    FactoryBot.create(:info_request, user: requester, prominence: prominence)
  end

  def reply_to(request)
    AttachmentFixtures.deliver(
      request, [['runs.txt', 'text/plain', "Gritting runs: 12\n"]]
    )
  end

  def hide(record, prominence = 'hidden')
    reason = 'Synthetic' unless prominence == 'normal'
    record.update!(prominence: prominence, prominence_reason: reason)
  end

  def draft_document(request = new_request)
    delivered_document(request, 'runs.txt', 'text/plain', "Gritting runs: 12\n")
  end

  def withdraw(document)
    Disclosures::Publication.new(document, user: requester).
      withdraw!(reason: 'Synthetic: no longer wanted')
    document.reload
  end

  def delete_request(request)
    Disclosures::RequestDeletion.new(InfoRequest.find(request.id), requester).
      delete!
  end

  def requester_may?(action, record)
    if action == :delete_request
      Disclosures::RequestDeletion.new(record.reload, requester).offered?
    else
      Ability.new(requester).can?(action, record.reload)
    end
  end

  def sending(request)
    ability = Ability.new(requester)
    { create_request: ability.can?(:create, InfoRequest),
      create_batch: ability.can?(:create, InfoRequestBatch),
      follow_up: ability.can?(:follow_up, request),
      send_reminder: ability.can?(:send_reminder, request) }
  end

  def suspend(account)
    if account == 'closed'
      requester.close!
    else
      requester.update!(ban_text: 'Synthetic ban')
    end
  end

  describe 'requests' do
    [
      ['requester_only', seen_by(:requester, :admin)],
      ['hidden',         seen_by(:admin)]
    ].each do |prominence, row|
      it "#{prominence}: #{who(row)}" do
        expect(answers(new_request(prominence: prominence))).to eq(row)
      end
    end

    %w[normal backpage].each do |prominence|
      it "#{prominence} isn't a prominence a request can have" do
        request = FactoryBot.build(:info_request, user: requester,
                                                  prominence: prominence)
        expect(request).not_to be_valid
        expect(request.errors[:prominence]).to be_present
      end
    end
  end

  describe 'replies (IncomingMessage)' do
    [
      ['requester_only', 'normal',         seen_by(:requester, :admin)],
      ['requester_only', 'hidden',         seen_by(:admin)],
      ['hidden',         'normal',         seen_by(:admin)],
      ['hidden',         'hidden',         seen_by(:admin)]
    ].each do |request_prominence, reply_prominence, row|
      it "request #{request_prominence}, reply #{reply_prominence}: " \
         "#{who(row)}" do
        reply = reply_to(new_request(prominence: request_prominence))
        hide(reply, reply_prominence)
        expect(answers(reply.reload)).to eq(row)
      end
    end
  end

  describe 'outgoing messages (OutgoingMessage)' do
    [
      ['normal', seen_by(:requester, :admin)],
      ['hidden', seen_by(:admin)]
    ].each do |prominence, row|
      it "request requester_only, outgoing message #{prominence}: " \
         "#{who(row)}" do
        message = new_request(prominence: 'requester_only').
          outgoing_messages.first
        hide(message, prominence)
        expect(answers(message.reload)).to eq(row)
      end
    end
  end

  describe 'files (FoiAttachment)' do
    [
      ['public',         seen_by(:requester, :admin)],
      ['requester_only', seen_by(:requester, :admin)],
      ['hidden',         seen_by(:admin)]
    ].each do |prominence, row|
      it "request requester_only, file #{prominence}: #{who(row)}" do
        reply = reply_to(new_request(prominence: 'requester_only'))
        file = file_in(reply, 'runs.txt')
        hide(file, prominence)
        expect(answers(file.reload)).to eq(row)
      end
    end
  end

  describe 'documents (Disclosures::Document)' do
    {
      'a draft on a live request' => {
        read: seen_by(:requester, :admin),
        admin: seen_by(:admin)
      },
      'published' => {
        read: everyone,
        admin: seen_by(:admin)
      },
      'published, then its source file hidden' => {
        read: seen_by(:admin),
        admin: seen_by(:admin)
      },
      'published, then its request hidden' => {
        read: seen_by(:admin),
        admin: seen_by(:admin)
      },
      'published, then its source file made requester_only' => {
        read: seen_by(:requester, :admin),
        admin: seen_by(:admin)
      }
    }.each do |state, row|
      it state do
        document = draft_document
        unless state == 'a draft on a live request'
          publish(document, by: admin)
          case state
          when /source file hidden/
            hide(FoiAttachment.find(document.foi_attachment_id))
          when /source file made requester_only/
            hide(FoiAttachment.find(document.foi_attachment_id),
                 'requester_only')
          when /request hidden/
            hide(InfoRequest.find(document.info_request_id))
          end
        end
        expect_document_row(document.reload, row)
      end
    end
  end

  describe 'further rows' do
    # Closed accounts cannot sign in; this tests the Ability rule directly.
    %w[suspended closed].each do |account|
      it "a #{account} requester still sees all their requester-only " \
         'content' do
        request = new_request
        reply = reply_to(request)
        file = file_in(reply, 'runs.txt')
        document = document_from_attachment(file, by: requester)
        suspend(account)
        expect(
          request: answers(request.reload),
          reply: answers(reply.reload),
          file: answers(file.reload),
          document: answers(document.reload),
          document_pages: answers(document, :view_document_pages),
          documents_panel: answers(request, :see_document_panel)
        ).to eq(
          request: seen_by(:requester, :admin),
          reply: seen_by(:requester, :admin),
          file: seen_by(:requester, :admin),
          document: seen_by(:requester, :admin),
          document_pages: seen_by(:requester, :admin),
          documents_panel: seen_by(:requester, :admin)
        )
      end
    end

    it 'AI reading skips a closed requester, not a banned one' do
      reply = reply_to(new_request)
      suspend('suspended')
      expect(IncomingAttention::Input.available?(IncomingMessage.find(reply.id))).
        to be(true)
      requester.update!(ban_text: '')
      suspend('closed')
      expect(IncomingAttention::Input.available?(IncomingMessage.find(reply.id))).
        to be(false)
    end

    {
      publish_own_document: 'publish a document',
      withdraw_document: 'withdraw a published document',
      delete_request: 'delete their request',
      delete_document: 'delete a document never published',
      report: 'report their request'
    }.then do |actions|
      # account     action                today  intended
      [
        ['suspended', :publish_own_document, false, false],
        ['closed',    :publish_own_document, false, false],
        ['suspended', :withdraw_document,    true,  true],
        ['closed',    :withdraw_document,    false, false],
        ['suspended', :delete_request,       true,  true],
        ['closed',    :delete_request,       false, false],
        ['suspended', :delete_document,      true,  true],
        ['closed',    :delete_document,      false, false],
        ['suspended', :report,               false, false],
        ['closed',    :report,               false, false]
      ].each do |account, action, today, intended|
        it "a #{account} requester #{intended ? 'can' : 'cannot'} " \
           "#{actions[action]}" do
          record = case action
                   when :withdraw_document
                     publish(draft_document, by: admin)
                   when :delete_request, :report then new_request
                   else draft_document
                   end
          expect(requester_may?(action, record)).to be(true)
          suspend(account)
          unless today == intended
            pending "a #{account} requester can " \
                    "#{actions[action]}"
          end
          expect(requester_may?(action, record)).to be(intended)
        end
      end
    end

    %w[suspended closed].each do |account|
      it "a #{account} requester cannot send" do
        request = new_request
        expect(sending(request).values).to all(be(true))
        suspend(account)
        expect(sending(request).values).to all(be(false))
      end
    end

    it 'a batch: its requester and admins; a suspended requester still reads ' \
       'it but neither downloads nor updates it' do
      batch = FactoryBot.create(:info_request_batch, user: requester)
      %i[read download update].each do |action|
        expect(answers(batch, action)).to eq(seen_by(:requester, :admin))
      end
      suspend('suspended')
      expect(answers(batch.reload).values_at(:requester)).to eq([true])
      expect(answers(batch, :download)[:requester]).to be(false)
      expect(answers(batch, :update)[:requester]).to be(false)
    end

    %w[banned closed].each do |account|
      it "a #{account} admin has no admin powers" do
        request = new_request
        hide(request)
        account == 'closed' ? admin.close! : admin.update!(ban_text: 'Ban')
        expect(Ability.new(admin.reload).can?(:read, request)).to be(false)
      end
    end

    it 'a file with an unknown prominence: admins only' do
      file = file_in(reply_to(new_request), 'runs.txt')
      file.update_column(:prominence, 'unknown')
      expect(answers(file.reload)).to eq(seen_by(:admin))
    end

    { 'an active' => 'active', 'a banned' => 'banned' }.each do |who, account|
      it "#{who} admin's own hidden reply isn't in their inbox" do
        request = FactoryBot.create(:info_request, user: admin)
        reply = reply_to(request)
        hide(reply)
        admin.update!(ban_text: 'Ban') if account == 'banned'
        inbox = IncomingAttention::Effective.
                relation(IncomingMessage.where(id: reply.id))
        expect(inbox).not_to exist
      end
    end

    it 'a hidden reply is neither the last one the requester sees nor ' \
       'answered' do
      request = new_request
      first = reply_to(request)
      second = reply_to(request)
      expect(request.reload.last_public_response).to eq(second)
      expect(request.who_can_followup_to.map(&:last)).to include(second.id)

      hide(second)
      expect(request.reload.last_public_response).to eq(first)
      expect(request.who_can_followup_to.map(&:last)).not_to include(second.id)
    end

    it 'only the requester follows up on a request or sends a reminder' do
      request = new_request
      expect(answers(request, :follow_up)).to eq(seen_by(:requester))
      expect(answers(request, :send_reminder)).to eq(seen_by(:requester))
    end

    it 'a request after the requester deletes it: nobody, it no longer exists' do
      request = new_request
      reply = reply_to(request)
      file = file_in(reply, 'runs.txt')
      delete_request(request)
      expect(InfoRequest.exists?(request.id)).to be(false)
      expect(IncomingMessage.exists?(reply.id)).to be(false)
      expect(FoiAttachment.exists?(file.id)).to be(false)
    end

    it 'a withdrawn document: the requester and admins only' do
      document = withdraw(publish(draft_document, by: admin))
      expect_document_row(
        document,
        read: seen_by(:requester, :admin),
        admin: seen_by(:admin)
      )
    end

    it 'a published document kept after its request was deleted: everyone' do
      request = new_request
      document = publish(draft_document(request), by: admin)
      delete_request(request)
      expect_document_row(
        document.reload,
        read: everyone,
        admin: seen_by(:admin)
      )
    end

    it 'a document kept after its request was deleted, then withdrawn: ' \
       'the requester and admins only' do
      request = new_request
      document = publish(draft_document(request), by: admin)
      delete_request(request)
      withdraw(document.reload)
      expect_document_row(
        document.reload,
        read: seen_by(:requester, :admin),
        admin: seen_by(:admin)
      )
    end
  end

  describe 'admins' do
    it 'a suspended admin reads nothing and has no admin powers' do
      document = draft_document
      request = document.info_request
      admin.update!(ban_text: 'Synthetic ban')
      ability = Ability.new(admin)
      expect(
        read_request: ability.can?(:read, request),
        admin_request: ability.can?(:admin, request),
        read_document: ability.can?(:read, document),
        admin_document: ability.can?(:admin, document)
      ).to eq(read_request: false, admin_request: false,
              read_document: false, admin_document: false)
    end
  end
end
