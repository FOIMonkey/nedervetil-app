# Guard Rails' own Active Storage controllers so signed blob/disk URLs are
# never served directly. ApplicationController declares the main privacy gate.
Rails.application.config.to_prepare do
  unless ActiveStorage::BaseController <= PrivateArchive::StoragePolicy
    ActiveStorage::BaseController.include(PrivateArchive::StoragePolicy)
  end
  ActiveStorage::BaseController.before_action :private_archive_storage_denied
end
