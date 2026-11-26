module Disclosures
  # Reads only stored rows, so a page view never parses or masks a reply.
  class Panel
    # main: suggested/existing docs; folded: set-aside/unconvertible by label.
    Reply = Struct.new(:message, :rows, :main, :folded, :pending,
                       keyword_init: true)
    Row = Struct.new(:suggestion, :attachment, :name, :document, :email_text,
                     keyword_init: true)
    FOLDED = { 'set_aside' => N_('Set aside'),
               'none' => N_('Stays in the thread') }.freeze

    attr_reader :info_request, :ability

    def initialize(info_request, ability)
      @info_request = info_request
      @ability = ability
    end

    def documents
      @documents ||= share(
        with_events(Document.where(info_request_id: info_request.id).
                      order(:created_at).to_a)
      ).select { |document| ability.can?(:view_document_pages, document) }
    end

    def replies
      @replies ||= thread_messages.
        select { |message| ability.can?(:read, message) }.
        map { |message| reply_for(message) }
    end

    def reply_for(message)
      suggestions = suggestions_for(message)
      pending = stale?(message, suggestions)
      enqueue(message) if pending
      rows = rows_for(suggestions)
      main, folded = fold(rows, message)
      Reply.new(message: message,
                rows: rows,
                main: main,
                folded: folded,
                pending: pending)
    end

    def attachment_documents
      @attachment_documents ||=
        AttachmentDocuments.new(info_request.id).tap do |found|
          share(found.documents)
        end
    end

    private

    # Preloads events across both attachment and standalone documents once.
    def with_events(list)
      ActiveRecord::Associations::Preloader.new(
        records: attachment_documents.documents + list, associations: :events
      ).call
      list
    end

    # Attaches already-loaded request/part/message to avoid N+1 in checks.
    def share(list)
      thread_messages
      parts = thread_parts
      list.each do |document|
        if document.info_request_id == info_request.id
          document.association(:info_request).target = info_request
        end
        part = parts[document.foi_attachment_id] or next
        document.association(:foi_attachment).target = part
        document.association(:incoming_message).target = part.incoming_message
      end
    end

    def suggestions_for(message)
      @suggestions ||= begin
        ids = thread_messages.map(&:id)
        parts = thread_parts
        Suggestion.where(incoming_message_id: ids).to_a.each do |row|
          part = parts[row.foi_attachment_id]
          row.association(:foi_attachment).target = part if part
        end.group_by(&:incoming_message_id)
      end
      @suggestions.fetch(message.id, [])
    end

    def thread_parts
      info_request.incoming_messages.flat_map(&:foi_attachments).index_by(&:id)
    end

    def stale?(message, suggestions)
      parts = message.foi_attachments.
        select { |part| Suggester.eligible?(part) }
      # Erased or masking-failed parts keep stale rows and shouldn't re-trigger.
      current = suggestions.reject do |row|
        row.foi_attachment && !Suggester.eligible?(row.foi_attachment)
      end
      message.last_parsed.nil? ||
        current.any? { |row|
          row.foi_attachment.nil? || !row.fresh?(row.foi_attachment)
        } ||
        (parts.map(&:id) - current.map(&:foi_attachment_id)).any?
    end

    def rows_for(suggestions)
      readable = suggestions.select do |row|
        row.foi_attachment && ability.can?(:read, row.foi_attachment)
      end
      rows = readable.map do |row|
        Row.new(suggestion: row,
                attachment: row.foi_attachment,
                name: row.display_name,
                document: document_for(row),
                email_text: row.rule.to_s.start_with?('email'))
      end
      rows.sort_by! { |row| row.email_text ? 0 : 1 }
    end

    def fold(rows, message)
      routine = routine?(message)
      group = ->(row) {
        if routine && row.suggestion.suggestion == 'look'
          'set_aside'
        else
          row.suggestion.suggestion
        end
      }
      main, aside = rows.partition do |row|
        row.document || !FOLDED.key?(group.call(row))
      end
      folded = FOLDED.to_h do |key, label|
        [_(label), aside.select { |row| group.call(row) == key }]
      end
      [main, folded.reject { |_, list| list.empty? }]
    end

    def thread_messages
      Deadlines::Stage.share_thread(info_request)
    end

    def routine?(message)
      defined?(IncomingAttention::Labels) &&
        IncomingAttention::Labels.routine?(message)
    end

    def document_for(row)
      attachment_documents.for(row.foi_attachment_id)&.then do |document|
        ability.can?(:view_document_pages, document) ? document : nil
      end
    end

    def enqueue(message)
      key = "disclosures/suggest-enqueued/#{message.id}"
      return if Rails.cache.read(key)

      Rails.cache.write(key, true, expires_in: 5.minutes)
      SuggestJob.perform_later(message.id)
    rescue StandardError => e
      Rails.logger.error("Disclosures::Panel enqueue failed: " \
                         "#{e.class}: #{e.message}")
    end
  end
end
