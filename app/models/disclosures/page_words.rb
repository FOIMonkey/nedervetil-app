# == Schema Information
#
# Table name: disclosure_page_words
#
#  id         :bigint           not null, primary key
#  page_id    :bigint           not null
#  words      :jsonb            not null
#  pictures   :boolean          default(FALSE), not null
#  created_at :datetime         not null
#

module Disclosures
  # Per-page PDF word positions for the box editor's Find, selection, and
  # suggestions (kept only for pages with trusted text; pictures: true marks
  # pages with images whose text isn't indexed). Stored raw before request
  # masks, so only expose through AttachmentManagement::WordMap.for_editor.
  class PageWords < ApplicationRecord
    self.table_name = 'disclosure_page_words'

    belongs_to :page, class_name: 'Disclosures::Page', inverse_of: :words

    def self.page_ids(version)
      where(page_id: version.pages.select(:id)).pluck(:page_id).to_set
    end

    # A word is stored as [text, line, x0, y0, x1, y1], the box as fractions
    # of the page as shown; its id is its place on the page.
    def self.pack(words)
      words.map { |word| [word[:text], word[:line], *word[:box]] }
    end

    def map
      { state: 'ready',
        words: words.each_with_index.map do |(text, line, *box), index|
          { id: index.to_s, line: line, text: text, box: box }
        end }
    end
  end
end
