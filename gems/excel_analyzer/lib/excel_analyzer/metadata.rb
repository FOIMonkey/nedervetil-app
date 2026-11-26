# frozen_string_literal: true

require 'office_package/excel_metadata'

module ExcelAnalyzer
  ##
  # Checks an Excel (.xlsx/.xlsm/.xltx/.xltm) workbook for hidden data such as
  # hidden rows, columns, sheets, pivot caches, data models, named ranges and
  # external links using OfficePackage::ExcelMetadata.
  class Metadata
    def initialize(source)
      @bytes = read_bytes(source)
    end

    def to_h
      @to_h ||= OfficePackage::ExcelMetadata.call(@bytes)
    end

    private

    def read_bytes(source)
      if defined?(::Zip::File) && source.is_a?(::Zip::File)
        File.binread(source.name)
      elsif source.respond_to?(:read)
        source.rewind if source.respond_to?(:rewind)
        source.read.to_s.b
      elsif source.is_a?(Pathname) ||
            (source.is_a?(String) && !source.b.include?("\0") &&
             File.file?(source))
        File.binread(source)
      else
        source.to_s.b
      end
    end
  end
end
