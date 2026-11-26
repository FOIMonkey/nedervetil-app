module Disclosures
  # Documents awaiting administrator review before going public.
  class ReviewQueue
    Draft = Struct.new(:document, :waiting, :why, keyword_init: true) do
      def for_you?
        FOR_YOU.include?(waiting)
      end
    end

    WAITING = { you: 'Ready for you to check' }.freeze
    FOR_YOU = %i[you].freeze
    SOURCE_CHANGED = 'Withdrawn after a masking rule change'.freeze

    attr_reader :ability

    def initialize(ability)
      @ability = ability
    end

    def drafts
      @drafts ||= begin
        documents = Document.where(state: %w[draft published]).
          where(id: ReviewSubmission.pending_document_ids).
          includes(
            :events, :owner, :foi_attachment,
            { public_body: :translations },
            info_request: [:user, { public_body: :translations }]
          ).
          order(:created_at, :id).
          select do |document|
            ability.can?(:publish_document, document) &&
              ReviewSubmission.pending?(document)
          end
        documents.map do |document|
          Draft.new(document: document, waiting: :you,
                    why: ReviewSubmission.reason(document))
        end
      end
    end

    def source_changed
      @source_changed ||= Document.
        where(withdrawal_kind: 'source_changed').
        includes(
          { public_body: :translations },
          info_request: [{ public_body: :translations }]
        ).
        order(:updated_at, :id).
        select { |document| ability.can?(:publish_document, document) }
    end

    def erasing
      @erasing ||= Document.where(withdrawal_kind: 'erasing').
        order(:updated_at, :id).
        select { |document| ability.can?(:manage_document, document) }
    end

    def attachment_drafts
      return @attachment_drafts = [] if Disclosures.requester_editing?

      @attachment_drafts ||= AttachmentManagement::Revision.
        where(status: 'ready').
        includes(:user, foi_attachment: :incoming_message).
        order(:created_at, :id).
        reject { |revision| author_confirms?(revision) }.
        select do |revision|
          ability.can?(:replace_attachment, revision.foi_attachment)
        end
    end

    def count
      drafts.count(&:for_you?) + source_changed.size + attachment_drafts.size
    end

    def empty?
      drafts.empty? && source_changed.empty? && erasing.empty? &&
        attachment_drafts.empty?
    end

    private

    def author_confirms?(revision)
      revision.user.nil? ||
        revision.confirmable_by?(::Ability.new(revision.user))
    end
  end
end
