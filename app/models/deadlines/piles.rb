module Deadlines
  # A user's requests sorted into the dashboard's piles: needs you, late,
  # coming up and finished.
  module Piles
    NAMES = { needs: N_('Needs you'),
              overdue: N_('Late'),
              waiting: N_('Coming up'),
              finished: N_('Finished') }.freeze

    # unread: replies that need the requester, newest first.
    Row = Struct.new(:action, :pile, :unread, :documents,
                     keyword_init: true) do
      def request
        action.request
      end

      def published
        documents.fetch('published', 0)
      end

      def drafts
        documents.fetch('draft', 0)
      end

      def unread_files
        Batch.for(request)&.load_files
        unread.sum { |message| message.get_attachments_for_display.size }
      end
    end

    # Lazy per-pile preloader for events, files, and reminders.
    class Batch
      def self.attach(rows)
        batch = new(rows)
        rows.each { |row| row.request.deadlines_batch = batch }
      end

      def self.for(request)
        request.deadlines_batch
      end

      def initialize(rows)
        @rows = rows
      end

      def load_events
        return if @events_loaded

        @events_loaded = true

        preload(
          @rows.map(&:request).reject do |request|
            request.association(:info_request_events).loaded?
          end,
          :info_request_events
        )
        settled = @rows.select do |row|
          %i[waiting needs].include?(row.pile) && row.unread.empty?
        end
        latest = settled.filter_map do |row|
          row.request.info_request_events.
            select { |event| event.event_type == 'response' }.max_by(&:id)
        end
        preload(latest, :incoming_message)
      end

      def load_files
        return if @files_loaded

        @files_loaded = true

        preload(@rows.flat_map(&:unread), %i[raw_email foi_attachments])
      end

      def reminder(action)
        @reminders ||= Reminder.where(
          info_request_id: @rows.map(&:action).select(&:late?).
            map { |late| late.request.id }
        ).group_by(&:info_request_id)
        Reminder.among(@reminders.fetch(action.request.id, []),
                       action.kind,
                       action.date)
      end

      private

      def preload(records, associations)
        return unless records.any?

        ActiveRecord::Associations::Preloader.new(
          records: records,
          associations: associations
        ).call
      end
    end

    module_function

    def pile(action, unread)
      if unread.any? ||
         %i[action_required needs_attention].include?(action.group)
        return :needs
      end
      return :overdue if action.late?
      return :waiting if action.group == :awaiting_authority

      :finished
    end

    def for(user, today: Time.zone.today)
      requests = Overview.requests(user)
      messages = Overview.attention_messages(requests)
      unread = unread_by_request(messages)
      documents = document_counts(requests)
      rows = Overview.next_actions(requests,
                                   messages&.map(&:info_request_id)&.to_set,
                                   today: today).map do |action|
        id = action.request.id
        Row.new(action: action,
                pile: pile(action, unread.fetch(id, [])),
                unread: unread.fetch(id, []),
                documents: documents.fetch(id, {}))
      end
      grouped = rows.group_by(&:pile)
      NAMES.keys.index_with do |name|
        sort(grouped.fetch(name, []), name).tap { |list| Batch.attach(list) }
      end
    end

    def unread_by_request(messages)
      (messages || []).group_by(&:info_request_id).
        transform_values do |list|
          list.sort_by { |message| message[:sent_at] || message.created_at }.
            reverse
        end
    end

    def document_counts(requests)
      Disclosures::Document.
        where(info_request_id: requests.map(&:id), erased_at: nil).
        requester_visible.
        group(:info_request_id, :state).count.
        each_with_object(
          Hash.new { |hash, key| hash[key] = {} }
        ) do |((id, state), count), all|
          all[id][state] = count
        end
    end

    def sort(rows, pile)
      case pile
      when :finished
        rows.sort_by do |row|
          -(row.action.closure&.created_at || row.request.updated_at).to_i
        end
      when :needs
        unread, rest = rows.partition { |row| row.unread.any? }
        newest_unread_first(unread) + by_date(rest)
      else
        by_date(rows)
      end
    end

    def newest_unread_first(rows)
      rows.sort_by do |row|
        [-(row.unread.first[:sent_at] || row.unread.first.created_at).to_i,
         row.request.id]
      end
    end

    def by_date(rows)
      rows.sort_by do |row|
        [row.action.date || Date.new(9999), row.request.id]
      end
    end
  end
end
