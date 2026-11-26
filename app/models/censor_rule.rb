# == Schema Information
#
# Table name: censor_rules
#
#  id                  :integer          not null, primary key
#  text                :text             not null
#  replacement         :text             not null
#  last_edit_editor    :string           not null
#  last_edit_comment   :text             not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  regexp              :boolean          default(FALSE), not null
#  case_sensitive      :boolean          default(TRUE), not null
#  ignore_diacritics   :boolean          default(FALSE), not null
#  censorable_type     :string
#  censorable_id       :bigint
#  masking_finished_at :datetime
#  colour              :string           default("black"), not null
#

# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Redaction rule scoped to a request, authority, user or the whole site.
# Triggers re-masking of published Disclosures documents on save/destroy.
class CensorRule < ApplicationRecord
  include CensorRule::CannedReplacements
  include CensorRule::Diacritics
  include CensorRule::Expiry
  include CensorRule::Polymorphic
  include CensorRule::Regexp
  include CensorRule::Recordable

  validates_presence_of :text, :replacement,
                        :last_edit_comment, :last_edit_editor

  # Declared so the model loads before the colour migration runs.
  attribute :colour, :string
  enum :colour, Disclosures::RULE_COLOURS.index_by(&:itself), validate: true

  def reaches_requester?
    black? ||
      (saved_change_to_colour? && !previously_new_record? && !destroyed?)
  end

  before_save { self.masking_finished_at = nil if changed? }
  after_commit :censor_published_documents, on: %i[create update]
  after_commit :remask_after_black_delete, on: :destroy, if: :black?

  # Memoized per request/job because this is checked for every rule applied.
  def feature_enabled?(feature, *args)
    return super unless args.empty?

    Current.memo(:feature, feature) { super }
  end

  def text_pattern
    to_replace('UTF-8')
  end

  def apply_to_text(to_censor, redactable: nil, redacted_attribute: nil)
    apply(to_censor, redactable, redacted_attribute) do |content|
      content.gsub(to_replace('UTF-8'), replacement)
    end
  end

  def apply_to_binary(to_censor, redactable: nil, redacted_attribute: nil)
    apply(to_censor, redactable, redacted_attribute) do |content|
      pattern = byte_pattern(content.encoding) or next content

      content.gsub(pattern) do |match|
        match.gsub(single_char_regexp) { |m| 'x' * m.bytesize }
      end
    end
  end

  # Returns a byte-pass pattern for encoding, or nil if the rule is text-only
  # (e.g. Unicode properties or non-ASCII \u escapes incompatible with
  # ASCII-8BIT, which still apply in text passes).
  def byte_pattern(encoding)
    if ignore_diacritics? && !text.ascii_only? &&
       Encoding.find(encoding) == Encoding::ASCII_8BIT
      return
    end

    pattern = to_replace(encoding)
    text_only = pattern.is_a?(::Regexp) && pattern.fixed_encoding? &&
                !Encoding.compatible?(pattern.encoding, Encoding.find(encoding))
    pattern unless text_only
  rescue RegexpError
    nil
  end

  # Builds a PDFRedactor::Rule; legacy byte_pattern supports rules written in
  # raw PDF content-stream syntax.
  def pdf_rule
    legacy = byte_pattern('ASCII-8BIT')
    if regexp? || ignore_diacritics?
      PDFRedactor::Rule.new(make_regexp('UTF-8'), false, legacy)
    else
      PDFRedactor::Rule.new(PDFRedactor.tolerant(text, !case_sensitive?),
                            true, legacy, text)
    end
  end

  private

  def apply(to_censor, redactable, redacted_attribute)
    return nil if to_censor.nil?

    after = yield to_censor
    record_redaction(redactable, redacted_attribute,
                     before: to_censor, after: after)
    after
  end

  def to_replace(encoding)
    if regexp? || !case_sensitive? || ignore_diacritics?
      make_regexp(encoding)
    else
      encoded_text(encoding)
    end
  end

  def encoded_text(encoding)
    text.dup.force_encoding(encoding)
  end

  def single_char_regexp
    ::Regexp.new('.'.force_encoding('ASCII-8BIT'))
  end

  def censor_published_documents
    was_black = !previously_new_record? &&
                (colour_before_last_save == 'black' ||
                 (!saved_change_to_colour? && black?))
    Disclosures::RuleJob.start(self, was_black: was_black)
  end

  def remask_after_black_delete
    Disclosures::RuleJob.deleted(self)
  end
end
