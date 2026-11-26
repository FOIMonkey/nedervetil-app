require 'spec_helper'

# Only fork migrations are checked; upstream keeps its original versions. After
# a Rails upgrade, keep older fork migrations at their original version so
# rollback behavior does not change.
RSpec.describe 'Migration versions' do
  let(:first_fork_migration) { '20261006000100' }
  let(:oldest_allowed) { Gem::Version.new('8.1') }

  let(:fork_migrations) do
    Dir[Rails.root.join('db/migrate/*.rb')].
      select { |path| File.basename(path) >= first_fork_migration }.
      sort_by { |path| File.basename(path) }.
      map do |path|
        version = File.read(path)[/ActiveRecord::Migration\[(\d+\.\d+)\]/, 1]
        [File.basename(path), version && Gem::Version.new(version)]
      end
  end

  it 'finds the fork’s migrations' do
    expect(fork_migrations.size).to be >= 38
  end

  it 'gives each one a version' do
    unversioned = fork_migrations.select { |_, version| version.nil? }
    expect(unversioned.map(&:first)).to be_empty
  end

  it 'uses 8.1 or newer in each one' do
    old = fork_migrations.select do |_, version|
      version && version < oldest_allowed
    end
    expect(old.map(&:first)).to be_empty
  end

  it 'never goes back to an older version than an earlier migration used' do
    newest = nil
    older = fork_migrations.each_with_object([]) do |(file, version), found|
      next unless version

      if newest && version < newest
        found << "#{file} uses #{version} after #{newest}"
      end
      newest = [newest, version].compact.max
    end
    expect(older).to be_empty
  end
end
