# Propshaft fingerprints and serves the assets. Dart Sass (dartsass-rails)
# builds the stylesheets first: `bin/dev` watches them, `assets:precompile`
# builds them for a release. A theme puts its own images, fonts, scripts and
# Sass ahead of core's (see a theme's lib/alavetelitheme.rb).

# Sass sources and the stylesheet builds are build inputs, not assets to serve.
# Each set of themes builds into its own folder under app/assets/builds, which
# config/initializers/theme_loader.rb adds once the themes are loaded.
Rails.application.config.assets.excluded_paths += %w[
  app/assets/stylesheets
  vendor/assets/stylesheets
  app/assets/builds
].map { |path| Rails.root.join(path).to_s }

# The stylesheets the views link to. Each composes its parts with @use.
Rails.application.config.dartsass.builds = {
  'responsive/application.scss' => 'responsive/application.css',
  'responsive/print.scss' => 'responsive/print.css',
  'admin.scss' => 'admin.css',
  'admin/print.scss' => 'admin/print.css',
  'admin/editor.scss' => 'admin/editor.css'
}

# normalize and Foundation. A theme's stylesheets go ahead of these and of
# core's, so that its partials replace core's of the same name.
Rails.application.config.dartsass.build_options <<
  "--load-path=#{Rails.root.join('vendor/assets/stylesheets')}"
