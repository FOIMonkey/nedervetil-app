module Disclosures
  # Caps the documents one user makes in 24 hours.
  module Limits
    module_function

    def documents!(user)
      check!(user,
             Document.where(created_by: user),
             Disclosures.daily_documents,
             'document')
    end

    def check!(user, scope, limit, noun)
      key = ->(day) { "disclosures/made/#{noun}/#{user.id}/#{day.iso8601}" }
      today = Time.zone.today
      counted =
        Rails.cache.increment(key.call(today), 1, expires_in: 2.days).to_i +
        Rails.cache.read(key.call(today - 1), raw: true).to_i
      made = [scope.where(created_at: 24.hours.ago..).count + 1, counted].max
      return if made <= limit

      raise Error::Refused,
            n_('You can share {{count}} document a day. Your files ' \
               'stay private. Try again tomorrow.',
               'You can share {{count}} documents a day. Your files ' \
               'stay private. Try again tomorrow.',
               limit,
               count: limit)
    end
  end
end
