class Ability
  # Admin read and management abilities across all records except erased files.
  # Included only when admin? is true.
  module AdminRules
    private

    def admin_rules
      can :access, :admin

      can %i[read admin], [InfoRequest, InfoRequestBatch]
      # A message or file is read only through its parent's :read.
      can :read, [IncomingMessage, OutgoingMessage] do |message|
        can?(:read, message.info_request)
      end
      can :read, FoiAttachment do |attachment|
        !RequesterVisible.nobody?(attachment) &&
          can?(:read, attachment.incoming_message)
      end

      can %i[read view_document_pages admin], Disclosures::Document
    end
  end
end
