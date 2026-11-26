require "mail"

require "active_storage"
require "active_storage/analyzer"

require "mail_handler"
require "mail_handler/report"
require "mail_handler/reading"

module ExcelAnalyzer
  ##
  # The EmlAnalyzer class extends the ActiveStorage::Analyzer to define a custom
  # analysis process for EML files. It checks for the presence of attachments
  # with content types associated with spreadsheet formats and invokes a
  # callback if necessary.
  class EmlAnalyzer < ActiveStorage::Analyzer
    CONTENT_TYPE = "message/rfc822".freeze

    # Only the raw-email copy: analysing the inbound copy of each email would
    # just download and parse it again.
    def self.accept?(blob)
      raw_copy = !defined?(ActionMailbox) ||
                 blob.service_name.to_s != ActionMailbox.storage_service.to_s
      raw_copy && blob.content_type == CONTENT_TYPE
    end

    # Only the types of the mail's parts are wanted, so none of their bytes
    # are read back (MailHandler::Reading).
    #
    # This only brings the callback forward: whatever parses the mail runs
    # the same check. So a mail that can't be read just now, or is past the
    # part limits, is left to that, and the analysis is not tried again.
    def metadata
      download_blob_to_tempfile do |file|
        parts = MailHandler::Reading.
                of(File.binread(file.path), bodies: false).parts

        if parts.any? { |part|
             ExcelAnalyzer.monitored?(content_type: part.content_type,
                                      filename: part.filename)
           }
          notify_spreadsheet_received
        end
      end

      {}
    rescue MailHandler::ReadRefused, MailHandler::TooComplex
      {}
    end

    private

    def notify_spreadsheet_received
      ExcelAnalyzer.on_spreadsheet_received.call(blob)
    rescue StandardError => e
      logger = Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
      return unless logger

      logger.warn("ExcelAnalyzer::EmlAnalyzer callback failed: #{e.class}")
    end
  end
end
