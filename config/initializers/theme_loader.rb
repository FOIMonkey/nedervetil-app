# This is a global array of route extensions. Alaveteli modules may add to it.
# It is used by our config/routes.rb to decide which route extension files to
# load.
$alaveteli_route_extensions = []

def theme_root(theme_name)
  Rails.root.join('lib/themes', theme_name)
end

def require_theme(theme_name)
  root = theme_root(theme_name)
  theme_lib = root.join('lib')
  $LOAD_PATH.unshift theme_lib.to_s

  theme_main_include = theme_lib.join('alavetelitheme.rb')

  Rails.configuration.paths['data'].push(root.join('data'))

  return unless File.exist?(theme_main_include)

  require theme_main_include

  # Let Zeitwerk ignore files which don't match the expected file structure
  Rails.autoloaders.main.ignore(theme_lib.join('customstates.rb'))

  Rails.configuration.paths['config/refusal_advice'].push(
    root.join('config/refusal_advice')
  )
end

Rails.configuration.paths.add('config/refusal_advice', glob: '*.{yml,yml.erb}')
Rails.configuration.paths.add('data')

if Rails.env == "test"
  # By setting this ALAVETELI_TEST_THEME to a theme name, theme tests can run in
  # the Rails context with the theme loaded. Otherwise the themes from the
  # config aren't loaded in testing so they don't interfere with core Alaveteli
  # tests
  themes = defined?(ALAVETELI_TEST_THEME) ? [ALAVETELI_TEST_THEME] : []
else
  themes = AlaveteliConfiguration.theme_urls.map do |url|
    theme_url_to_theme_name(url)
  end
end
themes.reverse_each { |theme| require_theme(theme) }

# Each set of themes builds its stylesheets into a folder of its own, so a
# build made with one set is never served with another.
stylesheet_builds = Rails.root.join(
  'app/assets/builds', themes.empty? ? 'core' : themes.join('+')
)
Rails.application.config.dartsass.builds.transform_values! do |output|
  stylesheet_builds.join(output).to_s
end
Rails.application.config.assets.paths << stylesheet_builds
