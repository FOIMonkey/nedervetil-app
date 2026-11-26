require 'digest'

# JSON-comparable snapshot of MailHandler's walk. Must stay plain Ruby (no
# Rails) so it can run standalone.
module MailPartsDescription
  FIELDS = %i[
    url_part_number content_type filename charset within_rfc822_subject
    hexdigest
  ].freeze

  UU_FIELDS = %i[url_part_number content_type filename hexdigest].freeze

  module_function

  # MailHandler mutates the Mail::Message and the app walks messages more than
  # once, so record a second walk too.
  def of(raw)
    mail = yield raw
    first = walk(mail)
    again = walk(mail)
    first.merge('second_walk' => again == first ? 'same' : again)
  end

  def walk(mail)
    parts = MailHandler.get_attachment_attributes(mail).map do |attrs|
      part(attrs)
    end
    { 'parts' => parts,
      'count_first_uudecode_count' => mail.count_first_uudecode_count }
  rescue StandardError => e
    { 'raised' => "#{e.class}: #{e.message}" }
  end

  def part(attrs)
    body, original = attrs.values_at(:body, :original_body)
    described = FIELDS.to_h { |name| [name.to_s, value(attrs[name])] }
    described['body'] = bytes(body)
    described['original_body'] = bytes(original)
    described['match_digests'] = [body, original].map do |text|
      attempt { MailHandler.calculate_hexdigest(text) }
    end
    if attrs[:content_type] == 'text/plain'
      number = attrs[:url_part_number]
      # As a parse finds them (in the bytes), and as the search for a stored
      # file's original does (in the text).
      described['uuencoded'] = blocks(body.b, number)
      described['uuencoded_as_text'] = blocks(body, number)
    end
    described
  end

  def blocks(text, number)
    attempt do
      MailHandler.uudecode(text, number).map do |block|
        UU_FIELDS.to_h { |name| [name.to_s, value(block[name])] }.
          merge('body' => bytes(block[:body]))
      end
    end
  end

  def value(value)
    return value unless value.is_a?(String)

    readable = value.dup.force_encoding('UTF-8')
    if readable.valid_encoding?
      { 'text' => readable, 'encoding' => value.encoding.name }
    else
      { 'hex' => value.unpack1('H*'), 'encoding' => value.encoding.name }
    end
  end

  def bytes(body)
    { 'sha256' => Digest::SHA256.hexdigest(body), 'bytes' => body.bytesize,
      'encoding' => body.encoding.name, 'valid' => body.valid_encoding? }
  end

  def attempt
    yield
  rescue StandardError => e
    { 'raised' => e.class.name }
  end
end
