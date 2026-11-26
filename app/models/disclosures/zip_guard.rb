module Disclosures
  # AttachmentManagement::ZipGuard, raising Disclosures errors for refusals.
  module ZipGuard
    Refused = Class.new(Error::Refused)

    module_function

    def check!(...)
      guard { AttachmentManagement::ZipGuard.check!(...) }
    end

    def checked!(...)
      guard { AttachmentManagement::ZipGuard.checked!(...) }
    end

    def count!(...)
      guard { AttachmentManagement::ZipGuard.count!(...) }
    end

    def read(...)
      guard { AttachmentManagement::ZipGuard.read(...) }
    end

    def guard
      yield
    rescue AttachmentManagement::ZipGuard::Refused => e
      raise Refused, e.message
    end
  end
end
