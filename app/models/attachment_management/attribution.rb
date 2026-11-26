module AttachmentManagement
  # Derived from applied revisions on the attachment.
  class Attribution
    # party: :requester/:site; verb: :redacted, :replaced, or :name_hidden.
    Change = Struct.new(:party, :verb, :at)

    attr_reader :attachment

    def initialize(attachment)
      @attachment = attachment
    end

    # "Redacted by the requester and by <the site's name>", or nil.
    def self.sentence(changes)
      verbs = changes.group_by(&:party).transform_values do |list|
        if list.any? { |change| change.verb == :replaced }
          'replaced'
        else
          'redacted'
        end
      end
      parts = []
      parts << [verbs[:requester], 'by the requester'] if verbs[:requester]
      if verbs[:site]
        parts << [verbs[:site], "by #{AlaveteliConfiguration.site_name}"]
      end
      return if parts.empty?

      (verb, who), other = parts
      text = "#{verb.capitalize} #{who}"
      return text unless other

      if other.first == verb
        "#{text} and #{other.last}"
      else
        "#{text} and #{other.first} #{other.last}"
      end
    end

    def text
      self.class.sentence(changes)
    end

    def changed_at
      changes.filter_map(&:at).max
    end

    # Walks applied revisions back while output_sha256 == next source_sha256;
    # restoring from email breaks the chain.
    def changes
      @changes ||= find_changes
    end

    private

    def find_changes
      applied = if attachment.association(:applied_revisions).loaded?
                  attachment.applied_revisions.to_a
                else
                  Revision.
                    where(foi_attachment_id: attachment.id, status: 'applied').
                    order(applied_at: :desc, id: :desc).to_a
                end
      return [] if applied.empty?

      chain = [applied.first]
      applied.drop(1).each do |revision|
        break unless revision.output_sha256 == chain.last.source_sha256

        chain << revision
      end
      chain.map { |revision| change_for(revision) }
    end

    def change_for(revision)
      # Inserted by Disclosures::ThreadSync.
      if revision.instructions.to_h.key?('disclosure_document_id')
        return Change.new(:site, :redacted, revision.applied_at)
      end

      # Fall back to current requester when older drafts omit by_requester.
      by_requester = revision.instructions.to_h.fetch('by_requester') do
        revision.user_id == requester_id
      end
      party = by_requester ? :requester : :site
      # A parent is the Office conversion the boxes were drawn on.
      replaced = %w[upload office_pdf].include?(revision.kind) ||
                 revision.parent_id.present?
      Change.new(party, replaced ? :replaced : :redacted, revision.applied_at)
    end

    def requester_id
      attachment.incoming_message&.info_request&.user_id
    end
  end
end
