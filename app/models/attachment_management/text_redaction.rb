module AttachmentManagement
  # Verifies text edits only replace non-empty runs with [redacted] (no adds or
  # alterations). Splits on markers and greedily matches surviving pieces in
  # order; earliest match finds a match whenever one exists.
  module TextRedaction
    MARKER = /\[redacted\]/i
    Rejected = Class.new(StandardError)

    def self.check!(current, edited)
      pieces = edited.split(MARKER, -1)
      if pieces.size == 1
        raise Rejected, _('Replace what should go with [redacted]; ' \
                          'nothing else may change.')
      end

      position = 0
      pieces.each_with_index do |piece, index|
        found = if index.zero?
                  current.start_with?(piece) ? 0 : nil
                elsif index == pieces.size - 1
                  start = current.size - piece.size
                  start if start > position && current.end_with?(piece)
                else
                  current.index(piece, position + 1)
                end
        raise Rejected, refusal(piece) unless found

        position = found + piece.size
      end
      true
    end

    def self.refusal(piece)
      words = piece.strip.truncate(60)
      where = if words.empty?
                _('next to a [redacted] marker')
              else
                PlainTextTranslation._('in “{{words}}”', words: words)
              end
      PlainTextTranslation._(
        'Only replacing text with [redacted] is allowed, and the rest ' \
        'must stay exactly as it was. Something was added, changed or ' \
        'deleted {{where}}.',
        where: where
      )
    end
  end
end
