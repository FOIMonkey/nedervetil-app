module Deadlines
  # The panel at the top of the requester's own page: which of its five forms
  # the request's next action calls for, and the facts each form prints.
  class NextStep
    RECEIPT_KINDS = %i[read_reply ask_review].freeze
    ACT_GROUPS = %i[action_required needs_attention].freeze

    attr_reader :action

    # arrived: true when a new reply is not yet reflected in request status.
    def initialize(action, unread:, ability:, arrived: false,
                   status_choices: nil)
      @action = action
      @unread = unread
      @ability = ability
      @arrived = arrived
      @status_choices = status_choices
    end

    def request
      action.request
    end

    def panel
      if receipt? then :receipt
      elsif action.closed? then :closed
      elsif action.none? then :done
      elsif act? then :act
      else :waiting
      end
    end

    def latest_reply
      return @latest_reply if defined?(@latest_reply)

      @latest_reply = action.closed? ? nil : Reply.latest(request, @ability)
    end

    def review_by
      if action.kind == :ask_review
        action.date
      elsif latest_reply.review_open? && !@arrived
        latest_reply.review_by
      end
    end

    # Coming up has a row for the review date, so the receipt leaves it out.
    def review_coming_up?
      RECEIPT_KINDS.include?(action.kind) && !action.late?
    end

    def change_status?
      @status_choices&.values&.any?(&:present?)
    end

    def completable?
      return @completable if defined?(@completable)

      @completable = @unread.empty? && !Closure.unread_replies?(request)
    end

    def decision
      event = if action.kind == :regulator
                Stage.review_response(request)
              else
                Stage.decision_response(request)
              end
      (event && History.reply_suffix(request, event)) ||
        InfoRequest::State.short_description(request.described_state)
    end

    def last_response
      return @last_response if defined?(@last_response)

      @last_response = request.last_public_response
    end

    def reply_to_read
      @unread.first || last_response
    end

    def long_date(date)
      I18n.l(date, format: '%-d %B')
    end

    def short_date(date)
      Overview.format_date(date)
    end

    private

    def receipt?
      latest_reply&.last? &&
        (RECEIPT_KINDS.include?(action.kind) || action.none? || @arrived)
    end

    def act?
      ACT_GROUPS.include?(action.group) || action.late?
    end
  end
end
