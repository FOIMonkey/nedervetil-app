require 'spec_helper'

# Managing never widens reading: the user must already be able to read the
# attachment and be its requester or an admin for the request.
RSpec.describe Ability::AttachmentRules do
  let(:owner) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:message) do
    AttachmentFixtures.deliver(
      info_request,
      [['letter.pdf', 'application/pdf',
        AttachmentFixtures.pdf(
          pages: [AttachmentFixtures.letter_page(secret: 'x')]
        )]]
    )
  end
  let(:attachment) { message.get_attachments_for_display.first }

  def manage?(user, record = attachment)
    Ability.new(user).can?(:manage_attachment, record)
  end

  it 'is private by default' do
    expect(info_request.prominence).to eq('requester_only')
    expect(Ability.new(FactoryBot.create(:user)).can?(:read, message)).
      to be false
    expect(Ability.guest.can?(:read, attachment)).to be false
  end

  it 'lets the requester and an admin manage, and nobody else' do
    expect(manage?(owner)).to be true
    expect(manage?(FactoryBot.create(:admin_user))).to be true
    expect(manage?(FactoryBot.create(:user))).to be false
    expect(manage?(nil)).to be false
  end

  it 'covers the message body part, which is a FoiAttachment too' do
    body_part = message.get_main_body_text_part
    expect(manage?(owner, body_part)).to be true
    expect(manage?(FactoryBot.create(:user), body_part)).to be false
  end

  it 'does not let the requester manage what only admins can read' do
    attachment.update!(prominence: 'hidden', prominence_reason: 'synthetic')
    expect(Ability.new(owner).can?(:read, attachment)).to be false
    expect(manage?(owner)).to be false
    expect(manage?(FactoryBot.create(:admin_user))).to be true
  end

  it 'refuses suspended accounts, even the requester' do
    owner.update!(ban_text: 'Synthetic ban')
    expect(manage?(owner)).to be false
    admin = FactoryBot.create(:admin_user, closed_at: Time.current)
    expect(manage?(admin)).to be false
  end

  it 'refuses an erased attachment' do
    attachment.update_columns(erased_at: Time.current)
    expect(manage?(owner)).to be false
    expect(manage?(FactoryBot.create(:admin_user))).to be false
  end

  it 'can be limited to admins on a site where requesters are the public' do
    with_setting(AttachmentManagement, :requester_access, 'none') do
      expect(manage?(owner)).to be false
      expect(manage?(FactoryBot.create(:admin_user))).to be true
    end
  end

  describe 'what a requester may do' do
    def replace?(user, record = attachment)
      Ability.new(user).can?(:replace_attachment, record)
    end

    around do |example|
      keeping_settings(AttachmentManagement, :requester_access) { example.run }
    end

    it 'is redaction only by default: no uploads, conversions or free edits' do
      expect(AttachmentManagement.requester_access).to eq('redact')
      expect(manage?(owner)).to be true
      expect(replace?(owner)).to be false
      expect(replace?(FactoryBot.create(:admin_user))).to be true
    end

    it 'can be widened to replacing, or closed, by the setting' do
      AttachmentManagement.requester_access = 'replace'
      expect(replace?(owner)).to be true
      AttachmentManagement.requester_access = 'none'
      expect(manage?(owner)).to be false
      expect(replace?(owner)).to be false
    end

    it 'reads the setting from general.yml, and treats a value it doesn’t know as none' do
      allow(AlaveteliConfiguration).
        to receive(:attachment_management_requester_access).
        and_return('replace')
      expect(AttachmentManagement.requester_access).to eq('replace')
      allow(AlaveteliConfiguration).
        to receive(:attachment_management_requester_access).
        and_return('everything')
      expect(AttachmentManagement.requester_access).to eq('none')
      expect(manage?(owner)).to be false
    end

    it 'never lets one user see another’s draft, except an admin' do
      admin = FactoryBot.create(:admin_user)
      admins_draft = AttachmentManagement::Revision.create!(
        foi_attachment: attachment, user: admin, kind: 'upload',
        status: 'ready', source_sha256: 'x',
        source_content_type: 'application/pdf', source_filename: 'letter.pdf'
      )
      owners_draft = admins_draft.dup.tap do |draft|
        draft.update!(user: owner, kind: 'pdf_redaction')
      end
      expect(Ability.new(owner).can?(:view_attachment_draft, admins_draft)).
        to be false
      expect(Ability.new(owner).can?(:view_attachment_draft, owners_draft)).
        to be true
      expect(Ability.new(admin).can?(:view_attachment_draft, owners_draft)).
        to be true
      expect(Ability.new(FactoryBot.create(:user)).
               can?(:view_attachment_draft, owners_draft)).to be false
    end
  end

  it 'lets the batch owner manage the attachments of each request in a batch' do
    pro_owner = FactoryBot.create(:pro_user, trusted: true)
    batch = FactoryBot.create(:info_request_batch, :sent,
                              user: pro_owner, public_body_count: 2)
    child = batch.info_requests.first
    child_attachment = AttachmentFixtures.deliver(
      child,
      [['c.pdf', 'application/pdf',
        AttachmentFixtures.pdf(
          pages: [AttachmentFixtures.letter_page(secret: 'x')]
        )]]
    ).get_attachments_for_display.first
    expect(manage?(pro_owner, child_attachment)).to be true
    expect(manage?(FactoryBot.create(:pro_user), child_attachment)).to be false
  end
end
