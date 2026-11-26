# Data files a theme supplies under its data/ directory, for features that
# work without them. A theme listed earlier in THEME_URLS loads later, so its
# copy wins.
module ThemeData
  module_function

  def file(name)
    files(name).last
  end

  def files(pattern)
    Rails.configuration.paths['data'].existent.
      flat_map { |dir| Dir[File.join(dir, pattern)] }.
      group_by { |path| File.basename(path) }.values.map(&:last).
      sort_by { |path| File.basename(path) }
  end
end
