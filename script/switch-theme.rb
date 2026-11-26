#!/usr/bin/env ruby

# A simple script to swap around your Alaveteli themes when you're
# hacking on Alaveteli.  By default this assumes that you have an
# 'alaveteli-themes' directory at the same level as your alaveteli git
# repository, e.g.:
#
# alaveteli
# ├── app
# ├── cache
# ...
# └── vendor
# alaveteli-themes/
# ├── alavetelitheme
# ├── asktheeu-theme
# ├── chiediamo-theme
# ├── ipvtheme
# ├── queremossabertheme
# ├── tuderechoasaber-theme
# ├── whatdotheyknow-theme
# └── yourrighttoknow
#
# However, you can override the location of your themes directory with
# the environment variable ALAVETELI_THEMES_DIR.
#
# You need to have a corresponding general.yml file called, for example:
#
#   config/general-whatdotheyknow-theme.yml
#   config/general-yourrighttoknow.yml

require 'tempfile'
require 'pathname'

NO_THEME_NAME = 'none'.freeze
theme_directory = ENV.fetch('ALAVETELI_THEMES_DIR', nil)
alaveteli_directory = File.expand_path(File.join(File.dirname(__FILE__),
                                                 ".."))
unless theme_directory
  theme_directory = File.expand_path File.join(alaveteli_directory,
                                               '..',
                                               'alaveteli-themes')
end

unless File.exist? theme_directory
  STDERR.puts "The theme directory '#{theme_directory}' didn't exist."
  exit 1
end

def show_themes
  AVAILABLE_THEMES.each do |theme_name|
    STDERR.puts "  #{theme_name}"
  end
end

# Assume that any directory directly under theme_directory is a theme:
ignored_entries = %w[. ..]
AVAILABLE_THEMES = Dir.entries(theme_directory).find_all do |local_theme_name|
  next if ignored_entries.index local_theme_name
  next unless local_theme_name

  full_path = File.join theme_directory, local_theme_name
  next unless File.directory? full_path
  next unless File.directory? File.join(full_path, '.git')

  local_theme_name
end.sort

AVAILABLE_THEMES.unshift NO_THEME_NAME

if AVAILABLE_THEMES.empty?
  STDERR.puts "There were no theme directories found in '#{theme_directory}'"
  exit
end

if ARGV.length == 1
  requested_theme = ARGV[0]
else
  STDERR.puts "Usage: #{$PROGRAM_NAME} <THEME-NAME>"
  show_themes
  exit 1
end

unless AVAILABLE_THEMES.include? requested_theme
  STDERR.puts "Theme '#{requested_theme}' not found in '#{theme_directory}'"
  STDERR.puts "Available themes:"
  show_themes
  exit 1
end

full_theme_path = File.join theme_directory, requested_theme

config_directory = File.join alaveteli_directory, 'config'
general_filename = File.join config_directory, "general.yml"
theme_filename = File.join config_directory, "general-#{requested_theme}.yml"

if File.exist?(general_filename) && !(File.symlink? general_filename)
  STDERR.puts "'#{general_filename}' exists, but isn't a symlink"
  exit 1
end

unless requested_theme == NO_THEME_NAME || File.exist?(theme_filename)
  STDERR.puts "'#{theme_filename}' didn't exist"
  exit 1
end

public_directory = File.join(alaveteli_directory, 'public')
public_theme_link = File.join(public_directory, 'alavetelitheme')

if requested_theme == NO_THEME_NAME &&
   File.exist?(public_theme_link) && !File.symlink?(public_theme_link)
  STDERR.puts "Couldn't remove #{public_theme_link} since it's not a symlink"
  exit 1
end

def symlink(target, link_directory, link_name)
  tmp = Tempfile.new link_name, link_directory
  full_link_name = File.join(link_directory, link_name)
  target = Pathname.new(target).relative_path_from(File.dirname(full_link_name))
  if system("ln", "-sfn", target.to_s, tmp.path)
    begin
      File.rename tmp.path, full_link_name
    rescue Errno::EISDIR
      STDERR.puts "Couldn't overwrite #{full_link_name} since it's a directory"
      exit 1
    end
  else
    STDERR.puts "Failed to create a symlink from #{tmp.path} to #{target}"
    exit 1
  end
end

symlink(File.join(alaveteli_directory, 'config', File.basename(theme_filename)),
        config_directory,
        "general.yml")

if requested_theme == NO_THEME_NAME
  File.unlink(public_theme_link) if File.symlink?(public_theme_link)
else
  symlink(File.join(full_theme_path, 'public'),
          public_directory,
          'alavetelitheme')

  symlink(full_theme_path,
          File.join(alaveteli_directory, 'lib', 'themes'),
          requested_theme)
end

STDERR.puts <<~MESSAGE
  Switched to #{requested_theme}!
  You will need to:
    1. restart any development server you have running (bin/dev builds the
       stylesheets for the new theme as it starts).
    2. run: bundle exec rake assets:precompile (in production)
    3. run: bundle exec rake assets:link_non_digest (in production)
MESSAGE
