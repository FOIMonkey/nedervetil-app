module Disclosures
  # Per-request/job cache of prior from_name values on an account's outgoing
  # messages, used by Checks.names_of.
  class EarlierNames < ActiveSupport::CurrentAttributes
    attribute :known

    def self.of(user)
      return user.previous_names unless user.try(:id)

      load([user])
      known[user.id]
    end

    def self.load(users)
      self.known ||= {}
      missing = users.compact.uniq.reject { |user| known.key?(user.id) }
      return if missing.empty?

      found = OutgoingMessage.joins(:info_request).
        where(info_requests: { user_id: missing.map(&:id) }).
        distinct.pluck('info_requests.user_id', :from_name).
        group_by(&:first)
      missing.each do |user|
        known[user.id] = found.fetch(user.id, []).filter_map(&:last) -
                         [user.read_attribute(:name)]
      end
    end
  end
end
