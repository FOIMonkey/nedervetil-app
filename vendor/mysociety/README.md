# mySociety commonlib (vendored subset)

These files come from mySociety's commonlib
(`git://git.mysociety.org/commonlib`, also github.com/mysociety/commonlib),
based on commit `20aef7e` (21 March 2026), which was the pinned submodule
commit. Some files have since received local fixes; see Git history. Only what
this app uses was kept:

- `rblib/config.rb` — `MySociety::Config`, which reads `config/general.yml`
- `rblib/validate.rb` — `MySociety::Validate`. `email_find_regexp` differs from
  upstream: where upstream's pattern finds no address, it also takes one whose
  last label is five or more letters, all lower case or all capitals and not
  followed by `@` or `://`, so the masks find addresses at domains such as
  gov.wales
- `rblib/format.rb` — `MySociety::Format`
- `rblib/util.rb` — `MySociety::Util`
- `rblib/debug_helpers.rb` — `MySociety::DebugHelpers`
- `rblib/external_command.rb` — `ExternalCommand`, which runs the document
  converters (see `AlaveteliExternalCommand` and the converter sandbox in
  `doc/FORK.md`)
- `rblib/git.rb` — `MySociety::Git`, used by `rake themes:install`
- `bin/run-with-lockfile.sh` — wraps the cron jobs in `config/crontab-example`

`config/initializers/alaveteli.rb` puts `rblib` on the load path. The licence
is in `LICENSE.txt`, and each file keeps its own copyright notice. If upstream
commonlib fixes something in one of these files, copy the change across by
hand.
