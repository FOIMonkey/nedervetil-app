module PrivateArchive
  # Active Storage controllers inherit ActionController::Base directly, so the
  # gate can't protect a leaked signed blob or disk URL.
  module StoragePolicy
    private

    def private_archive_storage_denied
      response.headers['cache-control'] = 'private, no-store'
      head :not_found
    end
  end
end
