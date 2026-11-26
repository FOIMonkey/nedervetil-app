# frozen_string_literal: true

module OfficePackage
  module Isolated
    # Strict schema and budget validation for structured sections in an Office
    # worker report, so a misbehaving worker cannot pass unexpected types or
    # unbounded manifest lists into the app.
    module ReportChecks
      EXCEL_COUNT_KEYS = %i[
        data_model external_links hidden_columns hidden_rows
        hidden_sheets named_ranges pivot_cache
      ].freeze

      private

      def excel_counts(value)
        raw = symbols(value)
        unless raw.size == EXCEL_COUNT_KEYS.size &&
               EXCEL_COUNT_KEYS.all? { |key| raw.key?(key) }
          raise TypeError, 'missing or unexpected excel counts'
        end

        EXCEL_COUNT_KEYS.each_with_object({}) do |key, out|
          out[key] = non_neg_int(raw.fetch(key), key)
        end
      end

      def zip_manifest(value)
        seen = non_neg_int(value.fetch(:seen), 'seen')
        limits = @zip || AlaveteliSandbox::OfficeStep::ZIP_LIMITS
        entries = slice_entries(
          value.fetch(:entries), :name,
          max_count: limits.fetch(:max_entries),
          max_total: limits.fetch(:max_total)
        )
        skipped = bounded_list(
          value.fetch(:skipped, []), OfficePackage::MAX_ENTRIES, 'skipped'
        ).map { |name| text_value(name, 'skipped') }
        { entries: entries, seen: seen, skipped: skipped }
      end

      def embedded_excel_manifest(value)
        cap = ExcelMetadata::MAX_EMBEDDED_PACKAGES
        spreadsheets = bounded_list(
          value.fetch(:spreadsheets), cap, 'spreadsheets'
        ).map do |item|
          row = symbols(item)
          { part: text_value(row.fetch(:part), 'part'),
            counts: excel_counts(row.fetch(:counts)) }
        end
        errors = bounded_list(value.fetch(:errors), cap, 'errors').map do |item|
          row = symbols(item)
          { part: text_value(row.fetch(:part), 'part'),
            error: text_value(row.fetch(:error), 'error') }
        end
        legacy = slice_entries(
          value.fetch(:legacy_xls), :part,
          max_count: ExcelMetadata::MAX_EMBEDDED_XLS,
          max_total: ExcelMetadata::MAX_EMBEDDED_TOTAL
        )
        { spreadsheets: spreadsheets, errors: errors, legacy_xls: legacy }
      end

      def bounded_list(raw, max, label)
        items = list(raw)
        raise TypeError, "too many #{label}" if items.size > max

        items
      end

      def slice_entries(raw, label_key, max_count:, max_total:)
        total = 0
        bounded_list(raw, max_count, label_key).map do |item|
          entry = symbols(item)
          size = non_neg_int(entry.fetch(:size), 'size')
          total += size
          if total > max_total
            raise TypeError, "#{label_key} slices exceed limit"
          end

          out = { label_key => text_value(entry.fetch(label_key), label_key),
                  :offset => non_neg_int(entry.fetch(:offset), 'offset'),
                  :size => size }
          if entry.key?(:index)
            out[:index] = non_neg_int(entry[:index], 'index')
          end
          out
        end
      end

      def text_value(value, label)
        return value if value.is_a?(String)

        raise TypeError, "#{label} is not text"
      end

      def non_neg_int(value, label)
        return value if value.is_a?(Integer) && value >= 0

        raise TypeError, "#{label} is not a non-negative integer"
      end
    end
  end
end
