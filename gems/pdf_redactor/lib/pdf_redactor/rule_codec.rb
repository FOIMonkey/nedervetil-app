# frozen_string_literal: true

require 'json'

module PDFRedactor
  # A small, explicit wire format for rules passed to the isolated redactor.
  # Marshal would deserialize attacker-controlled PDF-adjacent data as Ruby
  # objects, so the child accepts only JSON and these four fields. Its caps
  # (rules, bytes) apply only when the parser is isolated: in process, the
  # rules are passed as they are.
  module RuleCodec
    MAX_RULES = 1_000
    MAX_BYTES = 1024 * 1024
    ENCODINGS = %w[UTF-8 US-ASCII ASCII-8BIT].freeze
    VALID_OPTIONS = Regexp::IGNORECASE | Regexp::EXTENDED | Regexp::MULTILINE |
                    Regexp::FIXEDENCODING | Regexp::NOENCODING

    module_function

    def dump(rules)
      raise Error, 'PDF rule limit exceeded' if rules.size > MAX_RULES

      json = JSON.generate(rules.map do |rule|
        { 're' => encode(rule.re), 'literal' => rule.literal == true,
          'legacy' => encode(rule.legacy), 'text' => encode(rule.text) }
      end)
      raise Error, 'PDF rule data limit exceeded' if json.bytesize > MAX_BYTES

      json
    end

    def load(json)
      raise Error, 'PDF rule data limit exceeded' if json.bytesize > MAX_BYTES

      raw = JSON.parse(json)
      raise Error, 'PDF rules are invalid' unless raw.is_a?(Array) &&
                                                  raw.size <= MAX_RULES

      booleans = [true, false]
      raw.map do |item|
        unless item.is_a?(Hash) && item.keys.sort == %w[legacy literal re text]
          raise Error, 'PDF rule is invalid'
        end

        re = decode(item['re'])
        legacy = decode(item['legacy'])
        value = decode(item['text'])
        unless re.is_a?(Regexp) && (legacy.nil? || legacy.is_a?(Regexp) ||
                                    legacy.is_a?(String)) &&
               (value.nil? || value.is_a?(String)) &&
               booleans.include?(item['literal'])
          raise Error, 'PDF rule is invalid'
        end

        Rule.new(re, item['literal'], legacy, value)
      end
    rescue JSON::ParserError, ArgumentError, EncodingError, RangeError,
           RegexpError
      raise Error, 'PDF rule data is invalid'
    end

    def encode(value)
      case value
      when nil then nil
      when Regexp
        { 'kind' => 'regexp', 'source' => encode_string(value.source),
          'options' => value.options }
      when String
        { 'kind' => 'string', 'value' => encode_string(value) }
      else
        raise Error, 'PDF rule is invalid'
      end
    end

    def decode(value)
      return nil if value.nil?
      raise Error, 'PDF rule is invalid' unless value.is_a?(Hash)

      case value['kind']
      when 'regexp'
        opts = value['options']
        unless value.keys.sort == %w[kind options source] &&
               opts.is_a?(Integer) && opts >= 0 &&
               (opts & ~VALID_OPTIONS).zero?
          raise Error, 'PDF rule is invalid'
        end

        Regexp.new(decode_string(value['source']), opts)
      when 'string'
        raise Error, 'PDF rule is invalid' unless value.keys.sort == %w[kind
                                                                        value]

        decode_string(value['value'])
      else
        raise Error, 'PDF rule is invalid'
      end
    end

    def encode_string(value)
      unless ENCODINGS.include?(value.encoding.name) && value.valid_encoding?
        raise Error, 'PDF rule encoding is invalid'
      end

      { 'encoding' => value.encoding.name,
        'bytes' => [value.b].pack('m0') }
    end

    def decode_string(value)
      unless value.is_a?(Hash) && value.keys.sort == %w[bytes encoding] &&
             ENCODINGS.include?(value['encoding']) &&
             value['bytes'].is_a?(String)
        raise Error, 'PDF rule encoding is invalid'
      end

      bytes = value['bytes'].unpack1('m0')
      bytes.force_encoding(value['encoding'])
      raise Error, 'PDF rule encoding is invalid' unless bytes.valid_encoding?

      bytes
    end
  end
end
