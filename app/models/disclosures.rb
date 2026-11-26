# Released records and decision letters as documents of their own. Search is
# a PostgreSQL full-text index on these tables, not core's SearchDocument.
module Disclosures
  KINDS = %w[decision_letter released_records].freeze
  MASK_COLOURS = %w[black blue red orange].freeze
  RULE_COLOURS = %w[black blue].freeze

  mattr_accessor :ocr, :requester_editing, :review_requester_redactions

  def self.requester_editing?
    setting = if requester_editing.nil?
                AlaveteliConfiguration.disclosures_requester_editing
              else
                requester_editing
              end
    setting == true
  end

  # Always on while requester editing is off: an admin does the publishing
  # then, so a requester's redaction waits for one too.
  def self.review_requester_redactions?
    return true unless requester_editing?

    setting = if review_requester_redactions.nil?
                AlaveteliConfiguration.disclosures_review_requester_redactions
              else
                review_requester_redactions
              end
    setting == true
  end

  mattr_accessor :max_bytes, default: 50.megabytes
  mattr_accessor :render_max_pages, default: 150
  mattr_accessor :ocr_max_pages, default: 30
  mattr_accessor :sheet_max_rows, default: 2_000
  mattr_accessor :sheet_max_columns, default: 60
  mattr_accessor :sheet_display_rows, default: 500
  mattr_accessor :daily_documents, default: 20

  def self.ocr?
    on = (ocr.nil? ? AlaveteliConfiguration.disclosures_ocr : ocr) == true
    on && IncomingAttention::Outcome::Ocr.available?
  end

  def self.engine(job:)
    AttachmentManagement.engine(job: job)
  end
end
