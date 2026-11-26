# frozen_string_literal: true

module PDFRedactor
  ##
  # Writes a value from Lexer back as PDF syntax.
  module Serialize
    # Characters a name writes as #xx.
    NAME_ESCAPE = %r{[^!-~]|[()<>\[\]{}/%#]}n

    module_function

    def dump(v)
      case v
      when Float
        s = format('%.4f', v).sub(/\.?0+\z/, '')
        s == '-0' ? '0' : s
      when Name
        '/' + v.name.gsub(NAME_ESCAPE) { |c| format('#%02X', c.ord) }
      when PStr then '<' + v.bytes.unpack1('H*') + '>'
      when Array then '[' + v.map { |x| dump(x) }.join(' ') + ']'
      when Hash
        pairs = v.map { |k, x| "#{dump(Name.new(k))} #{dump(x)}" }
        "<<#{pairs.join(' ')}>>"
      when Ref then "#{v.num} #{v.gen} R"
      when true then 'true'
      when false then 'false'
      when nil then 'null'
      else v.to_s
      end
    end
  end
end
