# frozen_string_literal: true

# Runs a converter cell (AlaveteliSandbox::CellServer): the service that runs
# the app's conversion steps, as a user of its own. It loads the sandbox's
# code from this checkout and nothing else: no Rails and no gems.
#
# The PDF cell exits at once unless ImageMagick's policy in force is
# lib/alaveteli_sandbox/imagemagick-policy.xml (AlaveteliSandbox::ImagePolicy).
#
# Start it with `ruby --disable-gems script/sandbox_cell.rb`, so that Ruby
# looks for no gems at all.
#
# Settings, from the environment:
#
#   SANDBOX_CELL_KIND    pdf, office or mail: which programs this cell runs
#   SANDBOX_CELL_SOCKET  the UNIX socket to listen on, which the app is given
#                        as SANDBOX_PDF_CELL, SANDBOX_OFFICE_CELL or
#                        SANDBOX_MAIL_CELL
#   SANDBOX_CELL_SLOTS   steps to run at once (default 2)
#   SANDBOX_VOLUME       the conversion volume shared with the app
#                        (default /run/alaveteli-convert)
#   SANDBOX_BWRAP        bubblewrap (default /usr/bin/bwrap)
#   SANDBOX_MAIL_GEMS    for the mail cell: the directories of the gems the
#                        mail worker loads, separated by colons, as
#                        script/mail_worker_gems prints them one to a line
#   SANDBOX_OFFICE_GEMS  for the Office cell: the same for the Office worker,
#                        as script/office_worker_gems prints them
require 'find'
require 'json'
require 'rbconfig'
require 'socket'
require 'tmpdir'

root = File.expand_path('..', __dir__)
%w[
  alaveteli_sandbox
  alaveteli_sandbox/seccomp
  alaveteli_sandbox/bubblewrap
  alaveteli_sandbox/process_runner
  alaveteli_sandbox/redactor_step
  alaveteli_sandbox/worker_step
  alaveteli_sandbox/mail_step
  alaveteli_sandbox/office_step
  alaveteli_sandbox/image_policy
  alaveteli_sandbox/cell
  alaveteli_sandbox/cell_server
].each { |file| require File.join(root, 'lib', file) }

kind = ENV.fetch('SANDBOX_CELL_KIND')
gems = { 'mail' => ENV.fetch('SANDBOX_MAIL_GEMS', ''),
         'office' => ENV.fetch('SANDBOX_OFFICE_GEMS', '') }.fetch(kind, '')

AlaveteliSandbox::CellServer.new(
  kind: kind,
  socket: ENV.fetch('SANDBOX_CELL_SOCKET'),
  slots: Integer(ENV.fetch('SANDBOX_CELL_SLOTS', '2')),
  volume: ENV.fetch('SANDBOX_VOLUME', '/run/alaveteli-convert'),
  bwrap: ENV.fetch('SANDBOX_BWRAP', '/usr/bin/bwrap'),
  gems: gems.split(':').reject(&:empty?),
  root: root
).serve
