# The features admins can switch on per account. See Flipper's
# documentation for how features are stored:
# https://github.com/jnunemaker/flipper/blob/master/lib/flipper/dsl.rb

Rails.configuration.after_initialize do
  AlaveteliFeatures.features.add(
    :pro_batch_category_add_all,
    label: 'Batch category "add all" button'
  )
  AlaveteliFeatures.features.add(
    :database_backed_alerts,
    label: 'Generate alerts from the database instead of the search index'
  )
end
