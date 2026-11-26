module AttachmentManagement
  # Parses per-page redaction boxes as [x0, y0, x1, y1] top-left fractions
  # (0..1) so coordinates stay resolution-independent across renders.
  module Boxes
    Invalid = Class.new(StandardError)
    MAX_PER_PAGE = 200
    MIN_SIZE = 0.002

    def self.parse(json, page_count)
      data = JSON.parse(json.presence || '{}')
      raise Invalid, 'boxes must be an object' unless data.is_a?(Hash)

      data.each_with_object({}) do |(page, boxes), result|
        number = page_number!(page, page_count)
        raise Invalid, 'boxes must be a list' unless boxes.is_a?(Array)
        if boxes.size > MAX_PER_PAGE
          raise Invalid, _('too many boxes on page {{page}}', page: number)
        end

        cleaned = boxes.map { |box| box_from(box) }
        result[number] = cleaned if cleaned.any?
      end
    rescue JSON::ParserError
      raise Invalid, 'boxes are not valid JSON'
    end

    def self.page_number!(page, page_count)
      number = Integer(page, exception: false)
      raise Invalid, "no page #{page}" unless number&.between?(1, page_count)

      number
    end

    def self.box_from(box)
      unless box.is_a?(Array) && box.size == 4 && box.all?(Numeric)
        raise Invalid, 'each box needs four numbers'
      end

      x0, y0, x1, y1 = box.map { |v| v.to_f.clamp(0.0, 1.0) }
      x0, x1 = [x0, x1].minmax
      y0, y1 = [y0, y1].minmax
      if x1 - x0 < MIN_SIZE || y1 - y0 < MIN_SIZE
        raise Invalid, _('a box is too small')
      end

      [x0, y0, x1, y1].map { |v| v.round(6) }
    end

    # Stored with string page keys (JSON); used with integer ones.
    def self.from_instructions(instructions)
      instructions.fetch('boxes', {}).to_h { |page, boxes| [page.to_i, boxes] }
    end

    def self.count(boxes)
      boxes.values.sum(&:size)
    end
  end
end
