module IncomingAttention
  module Outcome
    # A reply often carries several documents: the letter, annexes, released
    # records (which may themselves be letters), leaflets and surveys. The
    # response letter talks to the requester about their request near the top.
    module LetterPick
      DOCS = %w[.pdf .doc .docx .odt .rtf .html .htm .txt].freeze
      # rubocop:disable Layout/LineLength
      LETTER = /\b(?:dear|yours (?:sincerely|faithfully)|kind regards|freedom of information|your request|request for information|environmental information|information request)\b/i
      RESPONSE_NAME = /respon|reply|answer|disclos|final|letter|decision|outcome/i
      ABOUT_REQUEST = /\b(?:your (?:request|e-?mail|letter|enquiry)|request (?:dated|received|of \d)|(?:our|your) ref(?:erence)?\b|request (?:ref|reference|number|no)\b|we (?:received|have considered))/i
      REGIME = /\b(?:freedom of information|environmental information regulations|foi(?:sa)?\b|eir\b)/i
      LEAFLET_NAME = /(?:review|complaints?|appeals?|foi)[ _-]*(?:procedures?|process|flow.?chart)|right.?to.?appeal|your.?rights|guidance.?notes|notes.?for.?applicants|copyright|privacy|charges|leaflet|re-?use|foi.?info\b/i
      LEAFLET_TEXT = /\b(?:review procedures?|what rights do i have|guidance notes|the review process|complaints procedure|your rights? summary)\b/i
      NOT_LETTER_NAME = /surve|questionnaire|feedback|annex|appendix|enclosure|attachment \d|schedule|spreadsheet|data|table|policy|minutes|agenda|report/i
      # rubocop:enable Layout/LineLength
      FLOOR = 3

      module_function

      def score(name, text)
        unless DOCS.include?(File.extname(name.to_s).downcase) &&
               text.to_s.strip.length >= 80
          return
        end

        head = text[0, 3000].split.join(' ')
        score = [head.scan(LETTER).size, 8].min
        score += 3 if name.match?(RESPONSE_NAME)
        score += 2 if head[0, 1500].match?(ABOUT_REQUEST)
        score += 1 if head[0, 1500].match?(REGIME)
        score -= 5 if leaflet?(name, head)
        if name.match?(NOT_LETTER_NAME) && !name.match?(RESPONSE_NAME)
          score -= 3
        end
        score
      end

      def leaflet?(name, text)
        (name.match?(LEAFLET_NAME) && !name.match?(RESPONSE_NAME)) ||
          text.to_s[0, 300].match?(LEAFLET_TEXT)
      end

      def pick(documents)
        scored = documents.filter_map do |name, text|
          (value = score(name, text)) && [value, name]
        end
        best = scored.max_by(&:first)
        best[1] if best && best[0] >= FLOOR
      end
    end
  end
end
