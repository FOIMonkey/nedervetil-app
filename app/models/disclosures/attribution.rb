module Disclosures
  # Derives redaction attribution and page box labels from applied revisions.
  class Attribution
    attr_reader :document

    def initialize(document, _version = nil)
      @document = document
    end

    def text
      AttachmentManagement::Attribution.sentence(changes)
    end

    def changed_at
      changes.filter_map(&:at).max
    end

    def changes
      @changes ||= find_changes
    end

    def boxes
      found = Hash.new { |hash, page| hash[page] = [] }
      attachment = document.foi_attachment or return found

      revisions = AttachmentManagement::Revision.
        where(foi_attachment_id: attachment.id,
              status: 'applied',
              kind: 'pdf_redaction').
        order(:applied_at, :id)
      revisions.each do |revision|
        party = revision.instructions.to_h['by_requester'] ? :requester : :site
        who = AttachmentManagement::Attribution.sentence(
          [AttachmentManagement::Attribution::Change.new(
            party, :redacted, revision.applied_at
          )]
        )
        AttachmentManagement::Boxes.
          from_instructions(revision.instructions.to_h).
          each do |page, list|
            list.each { |box| found[page] << [*box, who] }
          end
      end
      found
    end

    private

    def find_changes
      found = []
      if (attachment = document.foi_attachment)
        found.concat(AttachmentManagement::Attribution.new(attachment).changes)
      end
      restored_id = last_restored_event_id
      document.events.each do |event|
        next unless event.action == 'name_masked' && event.id > restored_id

        found << AttachmentManagement::Attribution::Change.new(
          :requester, :name_hidden, event.created_at
        )
      end
      found
    end

    def last_restored_event_id
      document.events.select do |event|
        event.action == 'withdrawn' &&
          event.details['start_again'] == true &&
          event.details['restored'] == true
      end.map(&:id).max.to_i
    end
  end
end
