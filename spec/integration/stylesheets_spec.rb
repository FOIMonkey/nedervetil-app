require 'spec_helper'

# Dart Sass builds the stylesheets and Propshaft serves them. A theme puts its
# Sass load path and asset folders ahead of core's; these check what that has
# to mean, with a made-up theme where one is needed.
RSpec.describe 'Stylesheets' do
  let(:assets) { Rails.application.assets }

  def urls(css)
    css.scan(/url\(\s*["']?([^"')\s]+)/).flatten.
      reject { _1.start_with?('data:', '#', '%23', 'http:', 'https:', '//') }
  end

  def compile(load_path:, entries:)
    command = [
      RbConfig.ruby, Dartsass::Runner::EXEC_PATH, "--load-path=#{load_path}",
      *Dartsass::Runner.dartsass_build_options,
      *Dartsass::Runner.dartsass_load_paths, *entries
    ]
    _out, err, status = Open3.capture3(*command)
    expect(status).to be_success, err
  end

  describe 'the built stylesheets' do
    let(:build_folder) { Rails.root.join('app/assets/builds/core') }
    let(:outputs) do
      Rails.application.config.dartsass.builds.values.map do
        Pathname.new(_1).relative_path_from(build_folder).to_s
      end
    end

    it 'are built for this set of themes into a folder of its own' do
      names = %w[
        responsive/application.css responsive/print.css admin.css
        admin/print.css admin/editor.css
      ]
      expect(outputs).to match_array(names)
      expect(Rails.application.config.assets.paths.map(&:to_s)).
        to include(build_folder.to_s)
    end

    it 'are served, and their Sass sources are not' do
      expect(outputs.map { assets.load_path.find(_1) }).to all(be_present)
      expect(assets.load_path.assets.map { _1.path.extname }.uniq).
        not_to include('.scss')
    end

    it 'link every image and font they use to an asset that exists' do
      outputs.each do |name|
        css = assets.load_path.find(name).compiled_content
        expect(css).not_to match(/(?:image|font|asset)-(?:url|path)\(/), name

        urls(css).each do |url|
          expect(url).to start_with('/assets/'), "#{name}: #{url}"
          path, digest = Propshaft::Asset.extract_path_and_digest(
            url.delete_prefix('/assets/')
          )
          expect(assets.load_path.find(path)&.digest).to eq(digest), url
        end
      end
    end
  end

  describe 'a theme' do
    let(:core) { Rails.root.join('app/assets/stylesheets') }
    let(:theme) { Pathname.new(Dir.mktmpdir('theme-assets')) }
    let(:out) { Pathname.new(Dir.mktmpdir('theme-builds')) }

    after { FileUtils.rm_rf([theme, out]) }

    it "replaces core's partial of the same name, and leaves the rest" do
      theme.join('responsive').mkpath
      theme.join('responsive/custom.scss').
        write(".made-up-theme-custom { color: #010203; }\n")

      entry = "#{core.join('responsive/application.scss')}:#{out.join('a.css')}"
      compile(load_path: theme, entries: [entry])

      css = out.join('a.css').read
      expect(css).to include('.made-up-theme-custom{color:#010203}')
      expect(css).to include('.modal-content{')
    end

    it 'leaves the parts core names by a relative path as they are' do
      theme.join('responsive').mkpath
      theme.join('responsive/_print_layout.scss').
        write(".made-up-theme-print { color: #010203; }\n")

      entry = "#{core.join('responsive/print.scss')}:#{out.join('p.css')}"
      compile(load_path: theme, entries: [entry])

      expect(out.join('p.css').read).not_to include('made-up-theme-print')
    end

    it "serves its image in place of core's, to helpers and stylesheets" do
      images = theme.join('images')
      images.join('status').mkpath
      sprite = images.join('status/status-sprite.png')
      sprite.binwrite(SecureRandom.bytes(64))
      styles = theme.join('styles')
      styles.mkpath
      styles.join('made-up.css').
        write('.status{background:url("/status/status-sprite.png")}')

      config = Rails.application.config.assets.dup
      config.paths = [images.to_s, styles.to_s, *config.paths]
      assembly = Propshaft::Assembly.new(config)
      resolver = Propshaft::Resolver::Dynamic.new(
        load_path: assembly.load_path, prefix: '/assets'
      )

      asset = assembly.load_path.find('status/status-sprite.png')
      expect(asset.path).to eq(sprite)
      expect(asset.content).to eq(sprite.binread)
      url = resolver.resolve('status/status-sprite.png')
      expect(url).to eq("/assets/status/status-sprite-#{asset.digest}.png")
      expect(assembly.load_path.find('made-up.css').compiled_content).
        to include(%(url("#{url}")))
    end
  end
end
