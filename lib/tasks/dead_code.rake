# CI check for unused partials, Stimulus controllers, methods and routes.
# Names built dynamically or used only by themes/add-ons belong in
# config/dead_code_allowlist.yml (full-match regexes) with a reason.
namespace :dead_code do
  allowed = ->(key, names) do
    patterns =
      YAML.load_file(Rails.root.join('config/dead_code_allowlist.yml')).
        fetch(key, {}).keys.map { /\A(?:#{_1})\z/ }
    names.reject { |name| patterns.any? { _1.match?(name) } }
  end

  read = ->(globs) do
    Dir[*globs.map { Rails.root.join(_1).to_s }].
      # rubocop:disable Layout/LineLength -- a regex
      select { File.file?(_1) && !_1.match?(/\.(png|jpe?g|gif|ico|pdf|afm|eml)\z/) }.
      # rubocop:enable Layout/LineLength
      to_h do
        [_1.delete_prefix("#{Rails.root}/"), File.read(_1, encoding: 'binary')]
      end
  end
  app_globs = %w[app/**/* lib/**/* config/**/* script/**/* db/seeds.rb]

  report = ->(title, unused) do
    next puts("#{title}: none unused") if unused.empty?

    puts "#{title} that nothing uses:", *unused.map { "  #{_1}" }
    abort 'Remove them, or add them to config/dead_code_allowlist.yml ' \
          'with the reason.'
  end

  desc 'Partials that nothing renders'
  task :partials do
    files = read.call(app_globs)
    unused = files.keys.grep(%r{\Aapp/views/.*/_[^/]+\z}).filter_map do |path|
      dir = File.dirname(path).delete_prefix('app/views/')
      name = File.basename(path).delete_prefix('_').sub(/\..*\z/, '')
      by_path = %r{["'/]#{Regexp.escape(dir)}/#{Regexp.escape(name)}["'\s,)]}
      by_name = /["':]#{Regexp.escape(name)}["'\s,)]/
      # rubocop:disable Layout/LineLength -- a regex
      local = %r{\A(app/views/#{Regexp.escape(dir)}/[^/]+|app/controllers/#{Regexp.escape(dir)}_controller\.rb)\z}
      # rubocop:enable Layout/LineLength
      used = files.any? do |other, text|
        other != path &&
          (text.match?(by_path) ||
           ((other.match?(local) || dir == 'application') &&
            text.match?(by_name)))
      end
      "#{dir}/#{name}" unless used
    end
    report.call('Partials', allowed.call('partials', unused))
  end

  desc 'Stimulus controllers that no view attaches'
  task :stimulus do
    files = read.call(app_globs)
    unused = files.keys.grep(
      %r{\Aapp/javascript/.*_controller\.js\z}
    ).filter_map do |path|
      id = File.basename(path, '_controller.js').tr('_', '-')
      # Matches data-controller, controller: hash key, or dataset.controller.
      # rubocop:disable Layout/LineLength -- a regex
      attached = /(data-controller\s*=|controller:|dataset\.controller\s*=)\s*\(?\s*
                  ["'][^"']*(?<![\w-])#{Regexp.escape(id)}(?![\w-])/x
      # rubocop:enable Layout/LineLength
      unless files.any? { |other, text| other != path && text.match?(attached) }
        id
      end
    end
    report.call('Stimulus controllers', allowed.call('stimulus', unused))
  end

  desc 'Methods whose name appears nowhere but their own definition'
  task :methods do
    files = read.call(app_globs + %w[spec/**/*.rb])
    counts = Hash.new(0)
    definitions = Hash.new(0)
    files.each_value do |text|
      text.scan(/[A-Za-z_]\w*[?!]?/) { counts[_1] += 1 }
      text.scan(/def\s+(?:self\.)?([A-Za-z_]\w*[?!]?)/) do
        definitions[_1.first] += 1
      end
    end
    unused = files.keys.grep(%r{\A(app|lib)/.*\.rb\z}).flat_map do |path|
      files[path].scan(/^\s*def\s+(?:self\.)?([A-Za-z_]\w*[?!]?)/).flatten.
        reject { _1 == 'initialize' || counts[_1] > definitions[_1] }.
        map { "#{path}##{_1}" }
    end
    report.call('Methods', allowed.call('methods', unused))
  end

  desc 'Routes without an action, and actions without a route'
  task routes: :environment do
    Rails.application.eager_load!
    routed = Rails.application.routes.routes.filter_map do |route|
      target = route.defaults.values_at(:controller, :action)
      target.join('#') if target.all?
    end.uniq

    missing = routed.reject do |target|
      controller, action = target.split('#')
      klass = "#{controller.camelize}Controller".safe_constantize
      klass && (klass.action_methods.include?(action) ||
        klass.new.lookup_context.exists?(action, klass._prefixes))
    end

    routed_controllers = routed.map { _1.split('#').first }.to_set
    unrouted = ApplicationController.descendants.flat_map do |klass|
      # A base controller only holds shared code for its subclasses; any other
      # controller without routes is reported in full.
      next [] if !routed_controllers.include?(klass.controller_path) &&
                 klass.descendants.any?

      own = klass.public_instance_methods(false).map(&:to_s)
      (klass.action_methods.to_a & own).map { "#{klass.controller_path}##{_1}" }
    end.uniq - routed

    report.call('Route targets', allowed.call('routes', missing))
    report.call('Controller actions', allowed.call('actions', unrouted))
  end
end

desc 'Check for unused partials, Stimulus controllers, methods and routes'
task dead_code: %w[dead_code:partials dead_code:stimulus dead_code:methods
                   dead_code:routes]
