module Disclosures
  # Decides whether a requester's disclosure document needs administrator review
  # before publication, tracks pending reviews and logs review submissions.
  module ReviewSubmission
    module_function

    UNWANTED = 'publication_unwanted'.freeze

    def required?(document, _version = nil, problems: nil)
      return true if pending?(document)
      return true if blue_rule_text_edit?(document)
      return false unless Disclosures.review_requester_redactions?
      return true if Titles.own_words?(document)

      found = problems || RequesterPublication.problems(document)
      return true if found.any? { |problem| problem.fix == :admin }

      changes = Attribution.new(document).changes
      changes.any? do |change|
        change.party == :requester && change.verb == :redacted
      end
    end

    def blue_rule_text_edit?(document)
      attachment = document.foi_attachment
      return false unless attachment&.main_body_part?

      AttachmentManagement::Revision.
        where(foi_attachment_id: attachment.id,
              kind: 'text_edit',
              status: 'applied').
        any? do |rev|
          rev.instructions['by_requester'] == true &&
            rev.instructions['blue_rule_matched'] == true
        end
    end

    def pending_document_ids
      Event.where(action: %w[review_requested published]).
        group(:document_id).having(<<~SQL.squish).select(:document_id)
          MAX(CASE WHEN action = 'review_requested' THEN id ELSE 0 END) >
          MAX(CASE WHEN action = 'published' THEN id ELSE 0 END)
        SQL
    end

    # Reads columns directly (never Document#stage, which calls this).
    def pending?(document)
      return false unless document.draft? || document.published?
      return false if document.erasure_started?
      return false if document.published? && !document.unpublished_changes?

      published = document.events.
        select { |event| event.action == 'published' }.map(&:id).max.to_i
      document.events.any? do |event|
        event.action == 'review_requested' && event.id > published
      end
    end

    # Latest post-review-request withdrawal of intent, from loaded events.
    def unwanted(document)
      requested = document.events.
        select { |event| event.action == 'review_requested' }.
        map(&:id).max.to_i
      document.events.
        select { |event| event.action == UNWANTED && event.id > requested }.
        max_by(&:id)
    end

    def unwanted!(document, user:)
      document.with_lock do
        unless Ability.new(user).can?(:mark_publication_unwanted, document)
          raise Error::Refused, _('This isn’t waiting for an admin.')
        end

        document.log!(UNWANTED, user: user)
      end
    end

    def reason(document)
      document.events.
        select { |event| event.action == 'review_requested' }.
        max_by(&:id)&.details&.dig('reason')
    end

    def submit!(document, user:, reason: nil, **)
      document.with_lock do
        unless Ability.new(user).can?(:publish_own_document, document)
          raise Error::Refused, _('You can’t submit that document for review.')
        end

        unless pending?(document)
          document.log!('review_requested', user: user,
                                            **{ reason: reason }.compact)
        end
        :review
      end
    end
  end
end
