module Disclosures
  # Resolves local disk paths for Active Storage blobs when on the Disk service.
  module Blobs
    module_function

    def local_path(attachment_proxy)
      return unless attachment_proxy&.attached?

      blob = attachment_proxy.blob
      return unless blob.service.respond_to?(:path_for)

      path = blob.service.path_for(blob.key)
      path if File.file?(path)
    end
  end
end
