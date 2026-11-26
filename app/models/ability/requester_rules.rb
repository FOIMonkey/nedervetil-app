class Ability
  # Read abilities for requesters on their own non-hidden requests, batches,
  # messages, attachments and documents. Applies even when the account is
  # suspended or closed.
  module RequesterRules
    private

    def requester_rules
      can :read, InfoRequest do |request|
        own_request?(request)
      end
      can :read, InfoRequestBatch do |batch|
        batch.user_id == user.id
      end
      # A message or file is read only through its parent's :read.
      can :read, [IncomingMessage, OutgoingMessage] do |message|
        RequesterVisible.requester?(message) &&
          can?(:read, message.info_request)
      end
      can :read, FoiAttachment do |attachment|
        RequesterVisible.requester?(attachment) &&
          can?(:read, attachment.incoming_message)
      end

      can :read, Disclosures::Document do |document|
        own_document?(document)
      end
      # Non-public management pages (unlike :read, which covers listed docs).
      can :view_document_pages, Disclosures::Document do |document|
        own_document?(document)
      end
    end

    def own_request?(request)
      requester_of?(request) && RequesterVisible.requester?(request)
    end
  end
end
