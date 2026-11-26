module Disclosures
  # Checks whether censor rules match a file's full content.
  module RuleCheck
    OFFICE = %w[document presentation spreadsheet].freeze
    PDF = 'pdf'.freeze
    FORMATS = [*OFFICE, PDF].freeze
    BLOCKED = N_('A masking rule matches words in this file, which would be ' \
                 'published as they are. Make a clean copy, or check them ' \
                 'before clearing.').freeze

    class Unreadable < StandardError; end

    module_function

    # read: optional OfficePackage::Isolated read that requested 'strings'.
    def match?(record, bytes, rules: rules_for(record),
               format: record.try(:format), read: nil)
      return false if rules.empty?
      return pdf_match?(record, bytes, rules) if format == PDF

      if OFFICE.include?(format)
        package = office_package_bytes(bytes, format)
        return office_match?(read, rules) if read && package.equal?(bytes)

        OfficePackage::Isolated.read(%w[strings], bytes: package) do |own|
          office_match?(own, rules)
        end
      else
        matched?(rules, convert_string_to_utf8(bytes.dup, 'UTF-8').string)
      end
    rescue OfficePackage::Error, OfficePackage::Isolated::ReaderError,
           LegacyOffice::ConversionError, ZipGuard::Refused,
           AlaveteliSandbox::Error => e
      unreadable!(record, e)
    end

    def office_package_bytes(bytes, format)
      return bytes if OfficePackage.package?(bytes) || !Formats.ole2?(bytes)

      case format
      when 'spreadsheet'
        LegacyOffice.to_ooxml(bytes, target: 'xlsx', extension: '.xls')
      when 'document'
        LegacyOffice.to_ooxml(bytes, target: 'docx', extension: '.doc')
      else
        bytes
      end
    end

    # Tests every string without short-circuiting so later timeouts still raise.
    def office_match?(read, rules)
      matched = false
      read.each_string { |text| matched = true if matched?(rules, text) }
      matched
    end

    def found?(record, bytes, format:, rules: rules_for(record), read: nil)
      match?(record, bytes, rules: rules, format: format, read: read)
    rescue Unreadable
      true
    end

    def pdf_match?(record, bytes, rules)
      PDFRedactor::FinalScan.check!(bytes, rules.map(&:pdf_rule))
      false
    rescue PDFRedactor::Matched
      true
    rescue StandardError => e
      unreadable!(record, e)
    end

    def matched?(rules, text)
      rules.any? { |rule| rule.apply_to_text(text) != text }
    rescue Regexp::TimeoutError => e
      raise Unreadable, "a rule timed out (#{e.class})"
    end

    def unreadable!(record, error)
      Rails.logger.warn(
        "Disclosures::RuleCheck #{record.class} #{record.id}: " \
        "#{error.class}: #{error.message}"
      )
      raise Unreadable, "#{error.class}: #{error.message}"
    end

    def rules_for(document)
      if document.info_request
        return document.info_request.applicable_censor_rules.to_a
      end

      scopes = [CensorRule.where(censorable_type: nil, censorable_id: nil)]
      scopes << CensorRule.where(censorable: document.owner) if document.owner
      if document.public_body
        scopes << CensorRule.where(censorable: document.public_body)
      end
      scopes.flat_map(&:to_a)
    end
  end
end
