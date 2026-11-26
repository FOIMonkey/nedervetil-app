This document has notes on a theme's assets: its images, fonts, scripts and
stylesheets. Propshaft fingerprints and serves every asset, and Dart Sass
(`dartsass-rails`) builds the stylesheets first.

Keep the theme's assets in its `app/assets` folder:

    app/assets
     \ fonts
     \ images
     \ javascripts
     \ stylesheets

A file in `fonts`, `images` or `javascripts` with the same name as one of
core's (for example `images/favicon.ico`) is served in its place. Refer to an
asset in a view with the Rails helpers (`image_tag`, `asset_path`,
`javascript_include_tag`), and in a stylesheet with a plain CSS URL from the
asset root, which Propshaft gives its fingerprinted address:

    background-image: url("/status/status-sprite.png");

A partial in `stylesheets` with the same name as one of core's (for example
`responsive/_settings.scss` or `responsive/custom.scss`) replaces it in core's
stylesheets. A part that core loads by a relative path stays core's. A
stylesheet of the theme's own, linked from its views, is an entry point the
theme names for the build.

Add this to `lib/alavetelitheme.rb`. Use `File.dirname(__FILE__)`, not
`__dir__`: the theme is reached through a link in `lib/themes`, and `__dir__`
would follow the link out of the Alaveteli folder.

    theme_assets =
      Pathname.new(File.dirname(__FILE__)).join('../app/assets').cleanpath

    # Sass looks in the theme's stylesheets before core's.
    Rails.application.config.dartsass.build_options.unshift(
      "--load-path=#{theme_assets.join('stylesheets')}"
    )
    # Only for a stylesheet of the theme's own.
    Rails.application.config.dartsass.builds[
      theme_assets.join('stylesheets/extra.scss').to_s
    ] = 'extra.css'

    # The theme's images, fonts and scripts win over core's. Propshaft puts the
    # app's own folders first as it starts, so this waits until it has.
    Rails.application.config.to_prepare do
      paths = Rails.application.config.assets.paths
      %w[fonts images javascripts].each do |type|
        path = theme_assets.join(type).to_s
        paths.unshift(path) unless paths.include?(path)
      end
    end

Every asset in those folders is served, so nothing needs listing for
production. Each set of themes builds its stylesheets into its own folder in
`app/assets/builds`; `bin/dev` builds and watches them in development, and
`bin/rails assets:precompile` builds them for production.
