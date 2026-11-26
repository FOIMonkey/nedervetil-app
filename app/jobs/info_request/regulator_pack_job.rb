# Builds a regulator pack zip in the background and emails an expiring link.
class InfoRequest::RegulatorPackJob < ApplicationJob
  queue_as :default

  MAX_MASKING_ATTEMPTS = 3
  MASKING_RETRY_KEY = [RegulatorPack::MaskingError].to_s.freeze

  retry_on MailHandler::ReadRefused, wait: :polynomially_longer, attempts: 5
  retry_on RegulatorPack::MaskingError, wait: :polynomially_longer,
                                        attempts: MAX_MASKING_ATTEMPTS

  def perform(info_request, user)
    token = RegulatorPack.new(
      info_request,
      user: user,
      retry_on_masking_error: retry_masking_errors?
    ).build!
    return unless token

    RequestMailer.regulator_pack_ready(info_request, user, token).deliver_now
  end

  private

  def retry_masking_errors?
    failures = (exception_executions || {})[MASKING_RETRY_KEY].to_i
    failures < MAX_MASKING_ATTEMPTS - 1
  end
end
