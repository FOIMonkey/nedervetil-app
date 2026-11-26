Rails.autoloaders.main.inflector.inflect(
  "alaveteli_gettext" => "AlaveteliGetText",
  "public_body_csv" => "PublicBodyCSV",
  "world_foi_websites" => "WorldFOIWebsites"
)

Rails.autoloaders.main.ignore(
  "lib/configuration.rb",
  "lib/i18n_fixes.rb",
  "lib/languages.rb",
  "lib/mail_handler/mail_extensions.rb",
  "lib/no_constraint_disabling.rb",
  "lib/normalize_string.rb",
  "lib/fetch_url.rb",
  "lib/routing_filters.rb",
  "lib/theme.rb",
  "lib/use_spans_for_errors.rb"
)
