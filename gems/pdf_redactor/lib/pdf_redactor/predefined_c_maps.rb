# frozen_string_literal: true

module PDFRedactor
  # Predefined CMaps (Table 118) by name: their codespace, writing mode and,
  # for the Unicode ones, how a code is Unicode.
  module PredefinedCMaps
    module_function

    def ranges(name)
      r = ->(len, lo, hi) { [len, [lo].pack('H*'), [hi].pack('H*')] }
      case name
      when /\AIdentity-[HV]\z/, /UCS2-[HV]\z/ then [r.call(2, '0000', 'ffff')]
      when /UTF16-[HV]\z/
        [r.call(2, '0000', 'd7ff'), r.call(4, 'd800dc00', 'dbffdfff'),
         r.call(2, 'e000', 'ffff')]
      when /UTF32-[HV]\z/ then [r.call(4, '00000000', '0010ffff')]
      when /UTF8-[HV]\z/
        [r.call(1, '00', '7f'), r.call(2, 'c280', 'dfbf'),
         r.call(3, 'e08080', 'efbfbf'), r.call(4, 'f0808080', 'f7bfbfbf')]
      when /RKSJ/
        [r.call(1, '00', '80'), r.call(1, 'a0', 'df'),
         r.call(2, '8140', '9ffc'), r.call(2, 'e040', 'fcfc')]
      when /EUC|GBK|GBpc|KSCms|KSCpc|UHC|B5|ETen|HKscs|ETHK|CNS/
        [r.call(1, '00', '80'), r.call(2, '8140', 'fefe')]
      when /\A[HV]\z|-[HV]\z/ then [r.call(2, '2121', '7e7e')]
      end
    end

    # The codes of the Uni... CMaps are Unicode in the CMap's own form.
    def unicode(name, bytes)
      case name
      when /UCS2-[HV]\z|UTF16-[HV]\z/ then PDFRedactor.utf16be(bytes)
      when /UTF8-[HV]\z/
        s = bytes.dup.force_encoding('UTF-8')
        s if s.valid_encoding?
      when /UTF32-[HV]\z/
        begin
          bytes.dup.force_encoding('UTF-32BE').encode('UTF-8')
        rescue EncodingError
          nil
        end
      end
    end

    def vertical?(name) = name.end_with?('-V') || name == 'V'
  end
end
