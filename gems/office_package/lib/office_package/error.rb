# frozen_string_literal: true

# What OfficePackage's readers share: its errors, and the most a file may
# unpack to. OfficePackage::CompoundFile needs only these, so it loads with
# this file and without the rest of OfficePackage, which needs Nokogiri.
module OfficePackage
  Error = Class.new(StandardError)

  # A zip this reader won't take: encrypted, split, ambiguous, overlapping,
  # over the limits, or an unknown compression method.
  Refused = Class.new(Error)

  # Bytes that aren't a zip at all, such as a compound file (an encrypted
  # Office file, or an old .doc).
  NotPackage = Class.new(Error)

  COMPOUND_FILE_MAGIC = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b.freeze

  # The most a zip's parts, or a compound file's streams, may add up to
  # unpacked. AttachmentManagement::ZipGuard's limit is this one.
  MAX_TOTAL = 200 * 1024 * 1024
end
