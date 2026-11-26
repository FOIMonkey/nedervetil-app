module Disclosures
  class Renderer
    # Accumulates render notes, findings, and flagged pages during rendering.
    class Outcome
      attr_reader :notes, :findings, :risky, :hidden_text, :masked,
                  :always_removed, :ocr_skipped, :unread, :flagged_text,
                  :flagged_read, :flagged_unread
      attr_accessor :page_count, :ocr_used, :hidden_in_file,
                    :always_removed_unknown

      def initialize
        @notes = {}
        @findings = []
        @risky = []
        @hidden_text = []
        @masked = []
        @always_removed = []
        @always_removed_unknown = false
        @ocr_used = 0
        @ocr_skipped = []
        @unread = []
        @flagged_text = {}
        @flagged_read = {}
        @flagged_unread = []
        @page_count = 0
      end

      def render_notes
        notes['ocr'] = Disclosures.ocr? ? 'on' : 'off'
        notes['ocr_pages'] = ocr_used if ocr_used.positive?
        notes['ocr_skipped'] = ocr_skipped if ocr_skipped.any?
        notes['unread_pages'] = unread if unread.any?
        notes['ocr_flagged'] = flagged_read if flagged_read.any?
        notes['unread_flagged'] = flagged_unread if flagged_unread.any?
        notes['hidden_text_pages'] = hidden_text.uniq.sort if hidden_text.any?
        notes['hidden_in_file'] = true if hidden_in_file
        notes['risky_hidden'] = risky.uniq if risky.any?
        notes['masked_pages'] = masked.uniq if masked.any?
        # Omit when unknown so callers distinguish unchecked from clean.
        unless always_removed_unknown
          notes['always_removed_pages'] = always_removed.uniq.sort
        end
        notes
      end
    end
  end
end
