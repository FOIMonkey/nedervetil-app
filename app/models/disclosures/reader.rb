module Disclosures
  # Builds the Text view from the document pages supplied by the caller.
  class Reader
    MAX_TERMS = 8
    REDACTED = '[redacted]'.freeze

    # blocks: [:lines, Array<String>] paragraphs or [:pre, String] for columns.
    Page = Struct.new(:page, :blocks, :matches)

    attr_reader :terms, :pattern, :pages

    # Splits terms (preserving a quoted phrase), ignoring "-word" and "or".
    def self.terms(find)
      text = find.to_s.squish.first(100)
      phrase = text[/\A"(.+)"\z/, 1]
      words = if phrase
                [phrase]
              else
                text.delete('"').split.reject do |word|
                  word.start_with?('-') || word.casecmp?('or')
                end
              end
      words.select { |word| word.length >= 2 }.uniq.first(MAX_TERMS)
    end

    # Joins lines reaching the right margin and drops OCR's mid-sentence gaps.
    def self.paragraphs(text)
      lines = text.to_s.split(/\r?\n/).map(&:strip)
      wide = lines.map(&:length).max.to_i * 0.7
      paragraphs = []
      current = nil
      gap = run_on = sentence_end = false
      lines.each do |line|
        next gap = true if line.empty?

        if current && run_on &&
           (!gap || (!sentence_end && line.match?(/\A[[:lower:]]/)))
          current[-1] << ' ' << line
        elsif current && !gap
          current << line
        else
          paragraphs << (current = [line])
        end
        run_on = line.length >= wide
        sentence_end = line.match?(/[.!?:;]["')”’]*\z/)
        gap = false
      end
      paragraphs
    end

    def initialize(pages, find: nil)
      @terms = self.class.terms(find)
      if terms.any?
        @pattern = Regexp.new(
          Regexp.union(terms.sort_by { |term| -term.length }).source,
          Regexp::IGNORECASE
        )
      end
      @pages = pages.select { |page| page.kind == 'image' }.
        map { |page| build(page) }
    end

    def find?
      terms.any?
    end

    def matches
      pages.sum(&:matches)
    end

    def matched_pages
      pages.select { |entry| entry.matches.positive? }.
        map { |entry| entry.page.number }
    end

    def any_text?
      pages.any? { |entry| entry.page.text.present? }
    end

    def ocr?
      pages.any? do |entry|
        entry.page.text_source == 'ocr' && entry.page.text.present?
      end
    end

    private

    def build(page)
      blocks = if page.text.blank?
                 []
               elsif page.columnar?
                 [[:pre, page.text]]
               else
                 self.class.paragraphs(page.text).
                   map { |lines| [:lines, lines] }
               end
      Page.new(page,
               blocks,
               pattern ? blocks.sum { |_, content| count(Array(content)) } : 0)
    end

    def count(texts)
      texts.sum { |text| text.gsub(REDACTED, ' ').scan(pattern).size }
    end
  end
end
