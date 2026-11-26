module IncomingAttention
  # Formats daily summary and instant notification emails from metadata only
  # (sender, file count, overdue state, and routine acknowledgement label).
  class Summary
    Row = Struct.new(:title, :line, :request, :message, :batch,
                     keyword_init: true)
    LATE = %w[overdue very_overdue].freeze
    SUBJECT_LIMIT = 30

    # presentation: Digest::Presentation, or nil when AI reading is off.
    def initialize(user, notifications, presentation = nil)
      @user = user
      @notifications = notifications
      @presentation = presentation
      preload
    end

    def needs
      @needs ||= rows(%i[needs_attention other_notices])
    end

    def also
      @also ||= rows(%i[routine_updates already_reviewed])
    end

    def subject
      replies = responses.size
      late = late_names
      if late.empty? && replies == 1
        one = PlainTextTranslation._(
          '{{public_body_name}} replied',
          public_body_name: replied_names.first
        )
        return one if one.length <= SUBJECT_LIMIT
      elsif replies.zero? && late.one?
        one = PlainTextTranslation._(
          '{{public_body_name}} is late',
          public_body_name: late.first
        )
        return one if one.length <= SUBJECT_LIMIT
      end

      [
        (n_('{{count}} reply', '{{count}} replies', replies,
            count: replies) if replies.positive?),
        (_('{{count}} late', count: late.size) if late.any?)
      ].compact.join(' · ').presence || PlainTextTranslation._('Your requests')
    end

    def preview
      parts = []
      if replied_names.any?
        parts << PlainTextTranslation._(
          '{{public_body_names}} replied.',
          public_body_names: names(replied_names)
        )
      end
      if late_names.any?
        parts << PlainTextTranslation.n_(
          '{{public_body_names}} is late.',
          '{{public_body_names}} are late.',
          late_names.size,
          public_body_names: names(late_names)
        )
      end
      parts.join(' ')
    end

    private

    # Preload associations; skip foi_attachments on unparsed replies.
    def preload
      events = @notifications.map(&:info_request_event)
      messages = events.filter_map(&:incoming_message)
      preloader = ActiveRecord::Associations::Preloader
      preloader.new(records: events.map(&:info_request),
                    associations: { public_body: :translations }).call
      preloader.new(records: messages, associations: :raw_email).call
      preloader.new(records: messages.select(&:last_parsed),
                    associations: :foi_attachments).call
    end

    def rows(keys)
      grouped(keys).map do |group, notifications|
        if group.is_a?(InfoRequestBatch)
          batch_row(group, notifications)
        else
          request_row(group, notifications, keys)
        end
      end
    end

    def grouped(keys)
      if @presentation
        keys.each_with_object({}) do |key, all|
          @presentation.sections.fetch(key).each do |group, list|
            (all[group] ||= []).concat(list)
          end
        end
      else
        return {} unless keys.include?(:needs_attention)

        @notifications.group_by do |notification|
          Digest.group_for(notification.info_request_event.info_request, @user)
        end
      end
    end

    def request_row(request, notifications, keys)
      replies = notifications.select do |notification|
        notification.info_request_event.event_type == 'response'
      end
      message = replies.last&.info_request_event&.incoming_message
      Row.new(title: request.title,
              request: request,
              message: message,
              line: "#{request.public_body.name} · " \
                    "#{what(request, notifications, replies, keys)}")
    end

    def what(request, notifications, replies, keys)
      if replies.any?
        if keys.include?(:routine_updates) &&
           replies.all? { |row| routine?(row) }
          return _('Got it')
        end

        reply_phrase(replies)
      elsif notifications.
              any? { |row| LATE.include?(row.info_request_event.event_type) } &&
            request.date_response_required_by
        _('Late · due {{date}}',
          date: request.date_response_required_by.strftime('%-d %b'))
      else
        _('Update')
      end
    end

    def reply_phrase(replies)
      files = replies.sum do |row|
        row.info_request_event.incoming_message&.
          get_attachments_for_display&.size.to_i
      end
      [
        if replies.one?
          _('Replied')
        else
          n_('{{count}} reply',
             '{{count}} replies',
             replies.size,
             count: replies.size)
        end,
        (n_('{{count}} file', '{{count}} files', files,
            count: files) if files.positive?)
      ].compact.join(' · ')
    end

    def routine?(notification)
      @presentation&.sections&.fetch(:routine_updates)&.values&.flatten&.
        include?(notification) &&
        @presentation.labels[notification.id] ==
          Labels::ROUTINE['ACKNOWLEDGEMENT']
    end

    def batch_row(batch, notifications)
      replies = notifications.count do |row|
        row.info_request_event.event_type == 'response'
      end
      late = notifications.count do |row|
        LATE.include?(row.info_request_event.event_type)
      end
      line = [
        (n_('{{count}} reply', '{{count}} replies', replies,
            count: replies) if replies.positive?),
        (_('{{count}} late', count: late) if late.positive?)
      ].compact.join(' · ')
      Row.new(title: batch.title,
              batch: batch,
              line: line.presence || _('Update'))
    end

    def responses
      @responses ||= @notifications.select do |row|
        row.info_request_event.event_type == 'response'
      end
    end

    def replied_names
      @replied_names ||= responses.
        map { |row| row.info_request_event.info_request.public_body.name }.uniq
    end

    def late_names
      @late_names ||= @notifications.
        select { |row| LATE.include?(row.info_request_event.event_type) }.
        map { |row| row.info_request_event.info_request.public_body.name }.uniq
    end

    def names(list)
      return list.first if list.one?
      if list.size == 2
        return PlainTextTranslation._(
          '{{public_body_name}} and {{other_public_body_name}}',
          public_body_name: list[0],
          other_public_body_name: list[1]
        )
      end

      PlainTextTranslation.n_(
        '{{public_body_name}}, {{other_public_body_name}} and ' \
        '{{count}} other',
        '{{public_body_name}}, {{other_public_body_name}} and ' \
        '{{count}} others',
        list.size - 2,
        public_body_name: list[0],
        other_public_body_name: list[1],
        count: list.size - 2
      )
    end
  end
end
