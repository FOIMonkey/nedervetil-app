require 'spec_helper'

RSpec.describe AttachmentManagement::Attribution do
  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:message) do
    AttachmentFixtures.deliver(
      info_request,
      [['notes.txt', 'text/plain', "Name: Alice Synthetic\nOutcome: upheld.\n"],
       ['briefing.docx',
        'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document',
        AttachmentFixtures.docx(paragraphs: ['Briefing'])]]
    )
  end
  let(:notes) do
    message.get_attachments_for_display.find { |a| a.filename == 'notes.txt' }
  end
  let(:docx) do
    message.get_attachments_for_display.
      find { |a| a.filename == 'briefing.docx' }
  end

  def apply!(record, user:, kind: 'text_edit', bytes: nil, content_type: nil, instructions: {}, parent: nil)
    attachment = FoiAttachment.find(record.id)
    current = attachment.body.to_s
    bytes ||= current.sub(/\A.*?\n/, "[redacted]\n").b +
              "#{SecureRandom.hex(4)}\n"
    type = content_type || attachment.content_type
    revision = AttachmentManagement::Revision.create!(
      foi_attachment: attachment, user: user, kind: kind, status: 'ready',
      parent: parent, source_sha256: Digest::SHA256.hexdigest(current),
      source_content_type: attachment.content_type,
      source_filename: attachment.display_filename, instructions: instructions,
      output_sha256: Digest::SHA256.hexdigest(bytes), output_content_type: type,
      output_filename: if type == 'application/pdf'
                         'briefing.pdf'
                       else
                         attachment.display_filename
                       end,
      output_byte_size: bytes.bytesize
    )
    revision.output.attach(io: StringIO.new(bytes),
                           filename: revision.output_filename,
                           content_type: type)
    AttachmentManagement::Replacement.new(
      revision,
      editor: user,
      reason: 'Synthetic attribution check'
    ).apply!
    revision.reload
  end

  def line(record)
    described_class.new(FoiAttachment.find(record.id)).text
  end

  it 'says nothing of a file as received, or of drafts nobody confirmed' do
    AttachmentManagement::Revision.create!(
      foi_attachment: notes, user: admin, kind: 'text_edit', status: 'ready',
      source_sha256: Digest::SHA256.hexdigest(notes.body.to_s),
      source_content_type: 'text/plain',
      source_filename: 'notes.txt'
    )
    expect(line(notes)).to be_nil
    expect(described_class.new(FoiAttachment.find(notes.id)).changed_at).
      to be_nil
  end

  it 'names the requester, the site, or both, with the date of the latest change' do
    apply!(notes, user: owner)
    expect(line(notes)).to eq('Redacted by the requester')

    latest = apply!(notes, user: admin)
    expect(line(notes)).to eq('Redacted by the requester and by ' \
                              "#{AlaveteliConfiguration.site_name}")
    expect(described_class.new(FoiAttachment.find(notes.id)).changed_at).
      to eq(latest.applied_at)

    other = FactoryBot.create(:info_request, user: admin)
    reply = AttachmentFixtures.deliver(
      other, [['other.txt', 'text/plain', "Officer: Bob Synthetic\n"]]
    )
    alone = reply.get_attachments_for_display.first
    apply!(alone, user: owner)
    expect(line(alone)).to eq("Redacted by #{AlaveteliConfiguration.site_name}")
  end

  it 'says replaced for an admin’s upload or conversion' do
    apply!(notes, user: owner)
    apply!(notes, user: admin, kind: 'upload',
                  bytes: "An admin's replacement\n")
    expect(line(notes)).to eq('Redacted by the requester and replaced by ' \
                              "#{AlaveteliConfiguration.site_name}")

    pdf = AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: 'Briefing')]
    )
    conversion = AttachmentManagement::Revision.create!(
      foi_attachment: docx, user: admin, kind: 'office_pdf', status: 'ready',
      source_sha256: Digest::SHA256.hexdigest(docx.body.to_s),
      source_content_type: docx.content_type,
      source_filename: 'briefing.docx'
    )
    apply!(docx, user: admin, kind: 'pdf_redaction', bytes: pdf,
                 content_type: 'application/pdf', parent: conversion)
    expect(line(docx)).to eq("Replaced by #{AlaveteliConfiguration.site_name}")
  end

  it 'counts a document version put into the thread as the site’s redaction, whoever pushed it' do
    apply!(notes, user: owner, kind: 'upload',
                  instructions: { 'disclosure_document_id' => 1,
                                  'disclosure_version' => 2 })
    expect(line(notes)).to eq("Redacted by #{AlaveteliConfiguration.site_name}")
  end

  it 'shows the line under the file in the thread to everyone who can read it' do
    redacted = apply!(notes, user: owner)
    body = apply!(message.get_main_body_text_part, user: admin)
    day = ->(revision) do
      revision.applied_at.in_time_zone.strftime('%B %d, %Y')
    end
    lines = ["Redacted by the requester, #{day.call(redacted)}",
             "Redacted by #{AlaveteliConfiguration.site_name}, " \
             "#{day.call(body)}"]

    # Only the requester and admins can read the request. The requester gets
    # their own page and an admin the standard one; both show the line.
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    page = Nokogiri::HTML(response.body)
    expect(page.css('.attachment__attribution').
             map { |node| node.text.squish }).to match_array(lines)
    expect(page.at_css("#attachment-#{notes.id} .attachment__attribution")).
      to be_present
    expect(page.at_css("#attachment-#{docx.id} .attachment__attribution")).
      to be_nil

    reset!
    sign_in(admin)
    get "/request/#{info_request.url_title}"
    page = Nokogiri::HTML(response.body)
    expect(page.at_css('body')['class']).not_to include('requester-view')
    expect(page.at_css("#attachment-#{notes.id} .attachment__attribution")).
      to be_present
    expect(page.at_css("#attachment-#{docx.id} .attachment__attribution")).
      to be_nil
  end
end
