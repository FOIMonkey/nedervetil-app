require 'spec_helper'

RSpec.describe Deadlines::Piles do
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
  include_context 'with document OCR off'

  it 'counts only the documents the requester can see' do
    owner = FactoryBot.create(:pro_user, trusted: true)
    request = FactoryBot.create(:info_request, user: owner)
    message = AttachmentFixtures.deliver(
      request,
      [['kept.txt', 'text/plain', "Ward: North\n"],
       ['hidden.txt', 'text/plain', "Zebracorn depot salt store\n"]]
    )
    documents = message.get_attachments_for_display.map do |attachment|
      Disclosures::Creation.new(user: owner,
                                attachment: attachment,
                                kind: 'released_records').create!
    end
    hidden = documents.find { |document|
      document.foi_attachment.filename == 'hidden.txt'
    }
    hidden.foi_attachment.update!(prominence: 'hidden',
                                  prominence_reason: 'Synthetic')

    expect(Ability.new(owner).can?(:read, hidden.reload)).to be false
    row = described_class.for(owner).values.flatten.find { |each|
      each.request.id == request.id
    }
    expect(row.drafts).to eq(1)
  end

  it 'counts as the requester check reads, whatever has happened to the source' do
    owner = FactoryBot.create(:pro_user, trusted: true)
    request = FactoryBot.create(:info_request, user: owner)
    names = %w[shown.txt hidden.txt blank.txt gone.txt moved.txt]
    documents = names.to_h do |name|
      message = AttachmentFixtures.deliver(
        request, [[name, 'text/plain', "Ward: North\n"]]
      )
      attachment = message.get_attachments_for_display.find { |part|
        part.filename == name
      }
      [name, Disclosures::Creation.new(user: owner,
                                       attachment: attachment,
                                       kind: 'released_records').create!]
    end
    documents['hidden.txt'].foi_attachment.update!(
      prominence: 'hidden',
      prominence_reason: 'Synthetic'
    )
    documents['blank.txt'].foi_attachment.update_column(:prominence, 'unknown')
    documents['gone.txt'].incoming_message.destroy
    documents['moved.txt'].incoming_message.
      update!(info_request: FactoryBot.create(:info_request))

    ruby = documents.values.map(&:reload).select { |document|
      Ability.new(owner).can?(:read, document)
    }.map(&:id)
    sql = Disclosures::Document.where(
      id: documents.values.map(&:id)
    ).requester_visible.pluck(:id)
    expect(sql).to contain_exactly(*ruby)
    expect(ruby).to eq([documents['shown.txt'].id])
  end
end
