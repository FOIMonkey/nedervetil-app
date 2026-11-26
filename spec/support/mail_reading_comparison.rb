module MailReadingComparison
  def exactly(value)
    case value
    when String then [value.b, value.encoding.name]
    when Hash then value.transform_values { |inner| exactly(inner) }
    when Array then value.map { |inner| exactly(inner) }
    else value
    end
  end

  def walked(raw)
    mail = Mail.from_source(raw)
    parts = MailHandler.get_attachment_attributes(mail)
    {
      parts: parts.map { |attrs| attrs.except(:original_body) },
      blocks: parts.map do |attrs|
        MailHandler.uudecode(attrs[:body].b, 0).
          map { |block| block.except(:url_part_number) }
      end,
      count: mail.count_first_uudecode_count
    }
  rescue MailHandler::TooComplex => e
    e
  end

  def read(reading)
    {
      parts: reading.parts.map(&:attributes),
      blocks: reading.parts.map { |part| part.uuencoded.map(&:to_h) },
      count: reading.count_first_uudecode_count
    }
  end

  def expect_reading_to_equal_walk(reading, raw)
    expected = walked(raw)
    expect(exactly(read(reading))).to eq(exactly(expected))
  end

  def original_fields(attributes)
    attributes&.slice(:url_part_number, :content_type, :filename,
                      :hexdigest, :body)
  end
end
