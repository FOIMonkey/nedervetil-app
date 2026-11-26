# frozen_string_literal: true

##
# Applies censor rules to a PDF by its text as a viewer draws it. A PDF's
# raw bytes rarely spell its words: fonts map codes to glyphs, and kerning
# splits words.
#
# 1. qpdf decrypts the file and unpacks object streams (QdfDoc). Streams stay
#    encoded, and only the ones read here are inflated, so images pass
#    through.
# 2. Each content stream is decoded as a viewer does: fonts, ToUnicode CMaps,
#    encodings, widths and glyph positions (Font, written from ISO 32000-1,
#    the Adobe Glyph List Specification and the OpenType cmap table).
# 3. The rules match the decoded text, in drawing order and again in reading
#    order. Each page is read with its own resources, with its own copy of any
#    stream it shares with another page.
# 4. Each marked glyph is removed, with TJ offsets keeping the layout, and a
#    black box saying [redacted] covers where it was. Rules written in
#    content-stream syntax still match the raw bytes afterwards, as x's.
# 5. PDF text strings, XMP and attached files say [redacted] instead. JPEG
#    metadata has to keep its length, so it gets x's.
# 6. With ocr, pages that are only pictures are read with tesseract. Words
#    that match are boxed, and those pages become pictures of themselves, with
#    no text layer, so no pixel is left under a box (Ocr). A page that can't
#    be read raises Error. Pages with an unapplied /Redact annotation also
#    become pictures, with its areas boxed, as they can cover anything.
# 7. The file is always rewritten, so old revisions and unreferenced objects
#    are gone.
# 8. Masking is best effort. A file that needs a password goes out as it
#    came (AlaveteliTextMasker), and so does an attached file that can't be
#    read; the report's unmasked_parts says which and why. Whether a file
#    can go public is checked when it's published (Disclosures::RuleCheck,
#    which reads a PDF whole with FinalScan).
#
# Credit to @GBP who is the inspiration behind reading PDFs from the decoded
# text.
#
#   masked, report = PDFRedactor.redact(pdf, rules, ocr: true)
#
module PDFRedactor
  Error = Class.new(StandardError)

  # A stream uses a filter this code does not decode. qpdf then decodes
  # every stream, which is slower: it inflates and deflates images.
  NeedsFullDecode = Class.new(Error)

  # The PDF needs a password to open, so it can't be read.
  PasswordRequired = Class.new(Error)

  # A rule matches in the file (FinalScan): what the scan looks for, where
  # every other Error is a part it couldn't read or a failure.
  Matched = Class.new(Error)

  # Bump when a change alters what PDFRedactor writes, so that stored PDFs are
  # masked again the next time their request is expired (FoiAttachment::
  # Maskable keeps a stored PDF while what goes into masking it is the same).
  VERSION = 17

  # re matches decoded text. legacy matches raw content-stream bytes, as the
  # old masker did, for rules written in content-stream syntax. text is a
  # literal rule's text, for fuzzy OCR matching.
  Rule = Struct.new(:re, :literal, :legacy, :text)

  Name = Struct.new(:name) do
    def to_s = name
  end
  Ref = Struct.new(:num, :gen)
  # bytes: the decoded string bytes (BINARY); span: [start, stop) in source.
  PStr = Struct.new(:bytes, :span)

  Glyph = Struct.new(:sid, :oi, :ei, :ci, :text, :x0, :y0, :x1, :y1, :ux, :uy,
                     :vx, :vy, :font_size, :invisible, :font)

  # A space the layout made, with no space glyph.
  GAP = "​"
  # A line break the layout made.
  LINE = " "
  REPLACEMENT = "�"

  # Adobe's glyph lists and Core 14 font metrics.
  DATA_DIR = File.expand_path('pdf_redactor/data', __dir__)

  # The largest file a qpdf step may hand back.
  MAX_BYTES = 256 * 1024 * 1024

  # Soft hyphens and zero-width characters are in some fonts' Unicode maps,
  # such as Chrome's for a word broken with &shy;. They never split a match.
  NFKC = Hash.new do |h, k|
    h[k] = begin
      k.unicode_normalize(:nfkc)
           rescue ArgumentError, Encoding::CompatibilityError
             k
    end.delete("­​-‍⁠﻿")
  end

  # [masked PDF, report]. First with streams left encoded, so that images
  # pass through untouched. final_scan: the result is read whole for the
  # rules (FinalScan), which raises if one still matches. A file that goes
  # public is checked so; masking for the requester is best effort.
  def self.redact(pdf, rules, ocr: false, depth: 0, final_scan: false)
    if isolated?
      return backend.redact(pdf, rules, ocr: ocr, depth: depth,
                                        final_scan: final_scan)
    end

    %w[none generalized].each do |level|
      qdf, = normalise(pdf, level)
      return redact_qdf(qdf, pdf, rules, ocr: ocr, depth: depth, level: level,
                                         final_scan: final_scan)
    rescue NeedsFullDecode
      raise if level == 'generalized'
    end
  rescue SystemStackError
    raise Error, 'PDF nesting limit exceeded'
  end

  # The application installs its worker and tool policy here. A standalone
  # process (including the worker itself) runs the tools locally.
  class << self
    attr_writer :backend
  end

  def self.backend = @backend || LocalTools
  def self.isolated? = backend.required?

  # qpdf's normalised file. Content stays as written, so legacy rules see the
  # bytes they did. This first step is the only one that may find the file
  # needs a password (PasswordRequired), which AlaveteliTextMasker serves as
  # it came, recorded for admins. That includes a file whose attached files
  # alone are encrypted (/EFF with /AuthEvent /EFOpen): readers show its
  # pages without a password, but qpdf can't open it.
  # A file that comes with no /ID is given one here, which the masked file
  # keeps. --deterministic-id makes it from the file's content, not the
  # clock, as the last step does (Redactor::COMPRESS).
  def self.normalise(pdf, level)
    qpdf(pdf, '--qdf', '--object-streams=disable', '--decrypt',
         '--normalize-content=n', "--decode-level=#{level}",
         '--deterministic-id')
  end

  # [masked PDF, report] from qpdf's normalised file.
  def self.redact_qdf(qdf, pdf, rules, ocr:, depth:, level:, final_scan:)
    redactor = Redactor.new(QdfDoc.new(qdf).unshare_contents, rules,
                            depth: depth, input: pdf, ocr: ocr)
    report = redactor.run
    out = redactor.write
    pages = redactor.rasterize
    if pages.any?
      out = Ocr.rasterize(out, pages)
      report['pages_rasterized'] = pages.size
    elsif report['boxes_over_images'].positive?
      report['notes'] << 'a box covers an image, but the image pixels ' \
                         'are still in the file'
    end
    report['changed'] ||= pages.any?
    report['full_decode'] = true if level == 'generalized'
    report['rules_matched'] = redactor.rules_matched
    FinalScan.check!(out, rules) if final_scan
    [out, report]
  rescue PasswordRequired
    # Only #normalise may find that the file needs a password.
    raise Error, 'a step after opening the file needed a password'
  end

  # qpdf's output for the file, and its warnings. qpdf warns when it repairs
  # something, and still succeeds.
  def self.qpdf(pdf, *args)
    backend.job(input: pdf, input_name: 'input.pdf') do |job|
      result = job.run('qpdf', '--warning-exit-0', job.input, *args, '-',
                       stdout: MAX_BYTES)
      [result.stdout, result.stderr]
    end
  rescue backend::ToolFailed => e
    raise PasswordRequired if e.result&.stderr.to_s.include?('invalid password')

    raise
  end

  def self.fix_qdf(qdf)
    backend.job(input: qdf, input_name: 'input.qdf') do |job|
      job.run('fix-qdf', job.input, stdout: MAX_BYTES).stdout
    end
  end

  # A literal also matches across layout gaps, line breaks and end-of-line
  # hyphens: a name in a narrow table cell wraps mid-word, and a heading with
  # letter spacing has a gap between each letter.
  def self.tolerant(text, ignore_case)
    parts = text.unicode_normalize(:nfkc).each_char.map do |c|
      c.match?(/\s/) ? "[\\s#{GAP}#{LINE}]+" : Regexp.escape(c)
    end
    body = parts.each_cons(2).map do |a, b|
      if a.start_with?('[\\s') || b.start_with?('[\\s')
        a
      else
        "#{a}(?:-?[#{GAP}#{LINE}]|#{GAP}?)"
      end
    end.join + parts.last.to_s
    Regexp.new(body, ignore_case ? Regexp::IGNORECASE : 0)
  end

  def self.utf16be(bytes)
    return bytes.unpack('C*').pack('U*') if bytes.bytesize.odd?

    bytes.dup.force_encoding('UTF-16BE').
      encode('UTF-8', invalid: :replace, undef: :replace)
  end

  def self.int(bytes) = bytes.unpack('C*').inject(0) { |n, b| (n << 8) | b }

  # Array() would turn a Name, a Struct, into its fields.
  def self.list(v)
    return v if v.is_a?(Array)

    v.nil? ? [] : [v]
  end

  # Each dictionary in a value, however deep, the value itself first.
  def self.each_dict(value, &block)
    case value
    when Array then value.each { |v| each_dict(v, &block) }
    when Hash
      yield value
      value.each_value { |v| each_dict(v, &block) }
    end
  end
end

require_relative 'pdf_redactor/local_tools'
require_relative 'pdf_redactor/serialize'
require_relative 'pdf_redactor/lexer'
require_relative 'pdf_redactor/qdf_doc'
require_relative 'pdf_redactor/encodings'
require_relative 'pdf_redactor/glyph_names'
require_relative 'pdf_redactor/predefined_c_maps'
require_relative 'pdf_redactor/c_map'
require_relative 'pdf_redactor/afm'
require_relative 'pdf_redactor/true_type_program'
require_relative 'pdf_redactor/font'
require_relative 'pdf_redactor/ocr'
require_relative 'pdf_redactor/redactor'
require_relative 'pdf_redactor/final_scan'
require_relative 'pdf_redactor/picture_cover'
require_relative 'pdf_redactor/survey'
require_relative 'pdf_redactor/rule_codec'
