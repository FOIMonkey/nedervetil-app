module Disclosures
  # Applies a requester's sharing choices for one reply atomically.
  class ReplyChoices
    attr_reader :documents, :user

    def initialize(documents, user:)
      @documents = documents
      @user = user
    end

    def reply
      @reply ||= Panel.new(info_request, ability).reply_for(message)
    end

    def title
      likely = reply.rows.count { |row| likely?(row) }
      if likely.positive?
        n_('Share this file?', 'Share these {{count}}?', likely, count: likely)
      elsif reply.pending && reply.rows.empty?
        _('Reading the reply')
      elsif reply.rows.any? && reply.rows.all? { |row| done?(row) }
        _('Already done')
      elsif reply.rows.any? { |row| done?(row) }
        _('Share anything else?')
      else
        _('Share anything?')
      end
    end

    def done?(row)
      document = row.document or return false
      !document.stage_in?(:held, :in_review, :not_ready, :ready) ||
        ReviewSubmission.pending?(document)
    end

    def likely?(row)
      (row.document && !done?(row) &&
        !documents.stuck?(row.document)) ||
        (!row.document && KINDS.include?(row.suggestion.suggestion) &&
         ability.can?(:create_document, row.attachment))
    end

    def likely
      reply.rows.select { |row| !row.document && likely?(row) }.to_h do |row|
        [row.attachment.id.to_s, row.suggestion.suggestion]
      end
    end

    # choices: attachment_id => kind or 'private'. Jobs/mail enqueue after
    # commit so a mid-batch refusal leaves nothing changed or queued.
    def apply!(choices)
      Document.transaction do
        choices.each_pair do |id, choice|
          attachment = message.foi_attachments.find_by(id: id) or next
          document = Document.find_by(foi_attachment_id: attachment.id)
          if document
            change!(document, choice.to_s)
          elsif KINDS.include?(choice)
            Creation.new(
              user: user,
              attachment: attachment,
              kind: choice,
              email_text: attachment.id == message.get_main_body_text_part&.id
            ).create!
          end
        end
      end
    end

    private

    def info_request
      documents.info_request
    end

    def message
      documents.message
    end

    def ability
      documents.ability
    end

    def change!(document, choice)
      document.with_lock do
        if choice == 'private'
          next unless ability.can?(:delete_document, document)

          document.purge_public_pages!
          document.destroy!
        elsif KINDS.include?(choice) && choice != document.kind &&
              ability.can?(:edit_document, document)
          attributes = { kind: choice, updated_by: user }
          if document.title == Titles.suggest(document.kind,
                                              info_request,
                                              document.released_on)
            attributes[:title] = Titles.suggest(choice,
                                                info_request,
                                                document.released_on)
          end
          document.update!(attributes)
          document.log!('details_changed',
                        user: user,
                        changes: document.saved_changes.slice('kind', 'title').
                          transform_values(&:last))
        end
      end
    end
  end
end
