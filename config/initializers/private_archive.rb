# The app's settings, and the guard on Active Storage's controllers.
# The features' own hooks are declared in the classes they extend.

Rails.application.config.after_initialize do
  ConverterSandboxCheck.verify!
end

Rails.application.config.to_prepare do
  # The privacy gate is declared in ApplicationController. Active Storage's
  # controllers are Rails' own, so their guard is added here.
  unless ActiveStorage::BaseController <= PrivateArchive::StoragePolicy
    ActiveStorage::BaseController.include(PrivateArchive::StoragePolicy)
  end
  ActiveStorage::BaseController.before_action :private_archive_storage_denied
end
