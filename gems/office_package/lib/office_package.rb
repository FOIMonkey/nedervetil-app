# frozen_string_literal: true

# Nokogiri reads Gem::Version and Gem::Platform even with explicit load paths.
require 'rubygems'
require 'nokogiri'
require 'office_package/error'

# Reads and rewrites Office Open XML packages (APPNOTE.TXT 6.3.10 and
# ECMA-376 Part 2). Unchanged packages without zip leftovers return the
# input bytes verbatim; modified ones are rewritten cleanly via Writer.
module OfficePackage
  autoload :Archive, 'office_package/archive'
  autoload :CompoundFile, 'office_package/compound_file'
  autoload :Detector, 'office_package/detector'
  autoload :ExcelMetadata, 'office_package/excel_metadata'
  autoload :Guard, 'office_package/guard'
  autoload :Hidden, 'office_package/hidden'
  autoload :Inspector, 'office_package/inspector'
  autoload :Package, 'office_package/package'
  autoload :Sheets, 'office_package/sheets'
  autoload :Tidy, 'office_package/tidy'
  autoload :Writer, 'office_package/writer'

  ZIP_MAGIC = "PK\x03\x04".b.freeze

  CONTENT_TYPES = '[Content_Types].xml'
  PACKAGE_RELS = '_rels/.rels'

  # Transitional and Strict spellings of the namespaces read here.
  RELATIONSHIPS_NS = %w[
    http://schemas.openxmlformats.org/officeDocument/2006/relationships
    http://purl.oclc.org/ooxml/officeDocument/relationships
  ].freeze
  WORD_NS = %w[
    http://schemas.openxmlformats.org/wordprocessingml/2006/main
    http://purl.oclc.org/ooxml/wordprocessingml/main
  ].freeze
  SPREADSHEET_NS = %w[
    http://schemas.openxmlformats.org/spreadsheetml/2006/main
    http://purl.oclc.org/ooxml/spreadsheetml/main
  ].freeze
  PACKAGE_RELS_NS =
    'http://schemas.openxmlformats.org/package/2006/relationships'
  CONTENT_TYPES_NS =
    'http://schemas.openxmlformats.org/package/2006/content-types'

  # The limits a zip is held to before anything parses it.
  MAX_ENTRIES = 2_000
  MAX_RATIO = 200
  # Small parts may compress far better than MAX_RATIO and are harmless.
  RATIO_FROM = 1024 * 1024
  MAX_PART = 20 * 1024 * 1024

  # What ActiveSupport's blank? takes for blank: Unicode spaces too.
  BLANK = /\A[[:space:]]*\z/

  DOCTYPE_MARKERS = %w[UTF-8 UTF-16LE UTF-16BE UTF-32LE UTF-32BE].map do |enc|
    '<!DOCTYPE'.encode(enc).b.freeze
  end.freeze

  module_function

  def doctype?(data)
    raw = data.to_s.b
    DOCTYPE_MARKERS.any? { |marker| raw.include?(marker) }
  end

  def blank?(text)
    text.nil? || BLANK.match?(text)
  end

  def read(bytes)
    Package.new(bytes)
  end

  def package?(bytes)
    bytes.to_s.byteslice(0, 4).to_s.b == ZIP_MAGIC
  end

  # The limits Guard holds a zip to, so a file this reads is one the rest of
  # the site will open.
  def limits
    { entries: MAX_ENTRIES,
      total: MAX_TOTAL,
      ratio: MAX_RATIO,
      ratio_from: RATIO_FROM,
      xml_part: MAX_PART }
  end
end
