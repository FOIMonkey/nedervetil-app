# Reverts a reported InfoRequest to its prior non-report classification,
# logging a status_update while keeping the report in history. Refuses if
# replies are unread, a send moved the state on, or a newer report arrived.
class InfoRequest::ReportReversion
  # Events that can report a request; other events may carry a reported state
  # passively (e.g. an auto-classified reply).
  REPORT_EVENTS = %w[report_request status_update edit].freeze
  # States a later send would have advanced (DeliveryTransitions).
  STATES_MOVED_BY_A_SEND = %w[waiting_clarification error_message].freeze
  SEND_EVENTS = %w[sent resent followup_sent followup_resent].freeze

  def initialize(info_request)
    @info_request = info_request
  end

  def last_report_event
    events = info_request.info_request_events.to_a
    report = report_index(events)
    events[report] if report
  end

  def last_classification_event_before_report
    events = info_request.info_request_events.to_a
    previous = previous_index(events, report_index(events))
    events[previous] if previous
  end

  def classification_before_report
    event = last_classification_event_before_report
    classification_of(event) if event
  end

  # Replies between the prior status and the report; InfoRequest#report!
  # counted as a human classification covering them.
  def replies_classified_by_report
    events = info_request.info_request_events.to_a
    report = report_index(events)
    previous = previous_index(events, report)
    return [] unless previous

    events[(previous + 1)...report].select do |event|
      event.event_type == 'response'
    end
  end

  def blocker
    return not_reported_error unless info_request.reported?
    if Deadlines::Closure.unread_replies?(info_request)
      return unread_replies_error
    end

    events = info_request.info_request_events.to_a
    previous = previous_index(events, report_index(events))
    return no_classification_error unless previous

    sent_since_report_error(events, previous)
  end

  def revert!(editor:, report_event_id: nil)
    info_request.with_lock do
      blocking_error = blocker
      raise blocking_error if blocking_error

      report = last_report_event
      check_report_fresh!(report, report_event_id)
      apply_reversion!(editor, report)
    end
  end

  private

  attr_reader :info_request

  def check_report_fresh!(report, report_event_id)
    return unless report_event_id && report.id != report_event_id.to_i

    raise InfoRequest::StaleReportError,
          'The request has been reported again since the page was ' \
          'loaded. Check the new report before reverting it.'
  end

  def apply_reversion!(editor, report)
    old_described_state = info_request.described_state
    revert_to_state = classification_before_report

    # Log the event before setting state so the classification lands on it.
    info_request.log_event(
      'status_update',
      editor: editor,
      old_described_state: old_described_state,
      described_state: revert_to_state,
      report_event_id: report.id
    )
    info_request.set_described_state(revert_to_state)
  end

  def not_reported_error
    InfoRequest::NotReportedError.new(
      'This request is not reported, so there is no report to revert.'
    )
  end

  def unread_replies_error
    InfoRequest::UnreadRepliesError.new(
      'A reply is waiting to be read, so the status can\'t be reverted. ' \
      'Classifying that reply will replace the report.'
    )
  end

  def no_classification_error
    InfoRequest::NoClassificationBeforeReportError.new(
      'There is no status from before the report to go back to. Set the ' \
      'status in Edit metadata.'
    )
  end

  def sent_since_report_error(events, previous)
    state = classification_of(events[previous])
    return unless STATES_MOVED_BY_A_SEND.include?(state)
    return if events.drop(previous + 1).none? do |event|
      SEND_EVENTS.include?(event.event_type)
    end

    InfoRequest::SentSinceReportError.new(
      "A message has been sent since the status was #{state}, so it is out " \
      'of date. Set the status in Edit metadata.'
    )
  end

  # Admin metadata edits record described_state in params rather than on the
  # event, and always submit it, so unchanged edits are not classifications.
  def classification_of(event)
    return event.described_state if event.described_state
    return unless event.event_type == 'edit'

    state = event.params&.dig(:described_state).presence
    return unless state

    state unless state == event.params[:old_described_state]
  end

  def report_index(events)
    events.rindex do |event|
      REPORT_EVENTS.include?(event.event_type) &&
        InfoRequest::REPORTED_STATES.include?(classification_of(event))
    end
  end

  def previous_index(events, report)
    return unless report

    events.take(report).rindex do |event|
      state = classification_of(event)
      state && !InfoRequest::REPORTED_STATES.include?(state)
    end
  end
end
