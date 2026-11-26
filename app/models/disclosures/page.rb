# == Schema Information
#
# Table name: disclosure_pages
#
#  id          :bigint           not null, primary key
#  number      :integer          not null
#  label       :string
#  kind        :string           not null
#  text        :text
#  text_source :string
#  text_note   :string
#  width       :integer
#  height      :integer
#  rows        :integer
#  columns     :integer
#  truncated   :boolean          default(FALSE), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  document_id :bigint           not null
#

module Disclosures
  # Search reads this text, so after a redaction it comes from the redacted
  # file.
  class Page < ApplicationRecord
    self.table_name = 'disclosure_pages'
    # Only the search SQL reads it, by name; loading it nearly doubles each page
    # row.
    self.ignored_columns += %w[search_vector]

    KINDS = %w[image sheet text].freeze

    belongs_to :document, class_name: 'Disclosures::Document',
                          inverse_of: :pages
    has_one_attached :image, service: :attachments
    # The database deletes them with the page.
    has_one :words, class_name: 'Disclosures::PageWords', inverse_of: :page

    validates :kind, inclusion: { in: KINDS }

    def anchor
      kind == 'sheet' ? "sheet-#{number}" : "page-#{number}"
    end

    # Text laid out in columns, such as a table read from a PDF, loses its
    # meaning if wrapped.
    def columnar?
      lines = text.to_s.lines.map(&:strip).reject(&:empty?)
      spaced = lines.count { |line| line.match?(/\S(?: {2,}|\t)\S/) }
      spaced >= 3 && spaced * 3 >= lines.size
    end

    def table_rows(limit: Disclosures.sheet_display_rows)
      text.to_s.split("\n").first(limit).map { |line| line.split("\t", -1) }
    end
  end
end
