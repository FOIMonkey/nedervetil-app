module Disclosures
  # Preloads a reply's active documents (excluding withdrawn/erased) for the
  # requester publishing steps.
  class ReplyDocuments
    attr_reader :info_request, :message, :ability

    def initialize(info_request, message, ability)
      @info_request = info_request
      @message = message
      @ability = ability
    end

    def all
      @all ||= Document.where(incoming_message_id: message.id,
                              info_request_id: info_request.id).
        includes(:events,
                 foi_attachment: [:file_blob, { file_attachment: :blob }]).
        order(:created_at, :id).
        select do |document|
          share_reply(document)
          ability.can?(:manage_document, document) &&
            !document.stage_in?(:erased, :erasing, :withdrawn, :taken_down)
        end
    end

    def find!(public_id)
      all.find { |document| document.public_id == public_id } or
        raise ActiveRecord::RecordNotFound
    end

    def ready?(document)
      document.servable?
    end

    def stuck?(document)
      document.stage_in?(:held, :in_review, :not_ready, :ready) &&
        !document.servable? && document.foi_attachment &&
        ability.can?(:delete_document, document)
    end

    def can_hide?(document)
      document.servable? && ability.can?(:redact_document, document)
    end

    # Polling status for waiting pages: ready when nothing is pending, stuck
    # when unready docs have no active processing.
    def status(with_reply: false)
      documents = all.to_h do |document|
        [document.public_id, ready?(document)]
      end
      waiting = documents.value?(false)
      stuck = waiting && all.none?(&:processing?)
      if with_reply
        stuck = false
        waiting ||= Panel.new(info_request, ability).reply_for(message).pending
      end
      { ready: !waiting, stuck: stuck, documents: documents }
    end

    def start_stuck_again!(user)
      stuck = all.select { |document| stuck?(document) }
      Document.transaction do
        stuck.each do |document|
          kind = document.kind
          attachment = document.foi_attachment
          email_text = document.source_kind == 'email_text'
          document.purge_public_pages!
          document.destroy!
          Creation.new(user: user, attachment: attachment, kind: kind,
                       email_text: email_text).create!
        end
      end
    end

    private

    # The checks read the request and reply this page has already loaded.
    def share_reply(document)
      document.association(:info_request).target = info_request
      document.association(:incoming_message).target = message
      part = document.foi_attachment or return
      part.association(:incoming_message).target = message
      part.association(:info_request).target = info_request
    end
  end
end
