module PrivateArchive
  # Fixed private-archive model policy, independent of feature flags (see
  # doc/FORK.md and spec/models/private_archive_policy_spec.rb).
  module Policy
    # Force correspondence search fields into the admin index while preserving
    # field weights and options.
    def self.searchable_options(index:, **options)
      options.merge(admin_index: index.merge(options.fetch(:admin_index, {})))
    end
  end
end
