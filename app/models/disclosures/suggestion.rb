# == Schema Information
#
# Table name: disclosure_suggestions
#
#  id                  :bigint           not null, primary key
#  incoming_message_id :bigint           not null
#  foi_attachment_id   :bigint           not null
#  fingerprint         :string           not null
#  rule_version        :integer          not null
#  suggestion          :string           not null
#  rule                :string
#  reason              :string
#  confident           :boolean          default(FALSE), not null
#  display_name        :string
#  content_type        :string
#  byte_size           :bigint
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#

module Disclosures
  # Suggester's stored result for one attachment of a reply.
  class Suggestion < ApplicationRecord
    self.table_name = 'disclosure_suggestions'

    belongs_to :incoming_message
    belongs_to :foi_attachment

    def fresh?(part)
      rule_version == Suggester::RULE_VERSION &&
        fingerprint == Suggester.fingerprint(part)
    end

    def label
      _(Suggester::LABELS.fetch(suggestion, suggestion.to_s.humanize))
    end

    # Stored rows show the current wording.
    def reason
      text = Suggester::EMAIL_REASONS.fetch(rule.to_s) { super() }
      text.present? ? _(text) : text
    end

    def set_aside?
      suggestion == 'set_aside'
    end

    # A reply's own text is more often the decision than the records.
    def kind
      if suggestion == 'decision_letter' || rule.to_s.start_with?('email')
        'decision_letter'
      else
        'released_records'
      end
    end
  end
end
