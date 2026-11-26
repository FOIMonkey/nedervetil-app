module RequestLimits
  # The words that tell a requester which limit they reached and when they
  # can send again.
  module Text
    NOUNS = {
      request: Nn_('a request', '{{count}} requests'),
      followup: Nn_('a message', '{{count}} messages')
    }.freeze

    module_function

    def reason(refusal)
      if refusal.kind == :batch_authorities
        return _('A batch request can go to at most {{count}} authorities.',
                 count: refusal.limit)
      end

      count = n_(*NOUNS.fetch(refusal.kind),
                 refusal.limit,
                 count: refusal.limit)
      period = refusal.window == 1.minute ? _('minute') : refusal.window.inspect
      if refusal.per_request
        _('You’ve sent {{count}} on this request in the last {{period}}.',
          count: count,
          period: period)
      else
        _('You’ve sent {{count}} in the last {{period}}.',
          count: count,
          period: period)
      end
    end

    # Rounded up, so the time shown is never a few seconds too early.
    def available_at(refusal)
      Time.zone.at((refusal.available_at.to_f / 60).ceil * 60) if
        refusal.available_at
    end

    def when_label(at, now = Time.current)
      time = at.strftime('%-l:%M%P')
      if at.to_date == now.to_date
        _('{{time}} today', time: time)
      else
        _('{{time}} on {{date}}', time: time, date: at.strftime('%A %-d %B'))
      end
    end
  end
end
