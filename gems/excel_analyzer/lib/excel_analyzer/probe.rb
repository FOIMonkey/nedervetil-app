# frozen_string_literal: true

require 'excel_analyzer/metadata'

module ExcelAnalyzer
  ##
  # Probe an Excel (.xlsx) IO object and return metadata with information about
  # the file.
  module Probe
    ZERO_COUNTS = {
      data_model: 0,
      external_links: 0,
      hidden_columns: 0,
      hidden_rows: 0,
      hidden_sheets: 0,
      named_ranges: 0,
      pivot_cache: 0
    }.freeze

    def probe(io)
      reader = ExcelAnalyzer.metadata_reader
      return reader.call(io.path) if reader

      Metadata.new(io.path).to_h
    end

    def probe_bytes(bytes, extension: '.xlsx')
      Tempfile.create(['excel-probe', extension]) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        probe(file)
      end
    end

    def suspected_problem?(data)
      return false unless data.is_a?(Hash)
      return true if data[:error]

      total_count = data.sum { |_k, v| v.to_i }
      return false if total_count == 0
      return false if data[:named_ranges] == total_count
      return false if data[:external_links] == total_count
      return false if data[:hidden_rows] == total_count && total_count <= 50

      true
    end

    # Combines per-spreadsheet results (from embedded workbooks or zip entries)
    # into a single metadata hash. Only spreadsheets that themselves trip
    # suspected_problem? contribute; any error takes precedence.
    def combine_problems(results)
      flagged = results.select { |item| suspected_problem?(item) }
      return nil if flagged.empty?

      errored = flagged.find { |item| item[:error] }
      return { error: errored[:error] } if errored

      ZERO_COUNTS.each_with_object({}) do |(key, _zero), merged|
        merged[key] = flagged.sum { |item| item[key].to_i }
      end
    end
  end
end
