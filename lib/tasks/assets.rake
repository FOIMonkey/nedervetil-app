namespace :assets do
  desc 'Link each asset at its plain name to its fingerprinted copy'
  task link_non_digest: :environment do
    config = Rails.application.config.assets
    JSON.parse(config.manifest_path.read).each do |logical_path, entry|
      digested_path = entry.fetch('digested_path')
      next if digested_path == logical_path

      # Both names are in the same folder, so the link is relative.
      FileUtils.ln_sf(File.basename(digested_path),
                      config.output_path.join(logical_path))
    end
  end
end
