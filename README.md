# Nedervetil

Nedervetil is an AGPL-3.0 fork of [Alaveteli](https://alaveteli.org) built around
**private-by-default Freedom of Information requests** and a **separate, reviewed
public documents catalogue**.

Request correspondence stays private to the requester and authorised
administrators. Documents selected from replies can be inspected, redacted,
reviewed, and published independently.

## Key Capabilities

- **Private-by-default archive:** Requests are `requester_only` (or `hidden`);
  public search indexes authorities, topics, and published documents rather than
  private request threads or user profiles.
- **Public documents & redaction workflow:** Requesters nominate reply
  attachments, edit or redact PDFs and Office files, and submit them to an admin
  review queue before publication.
- **Sandboxed document conversion:** PDF, Office, and mail converters run inside
  bubblewrap + seccomp-BPF converter cells (`pdf`, `office`, `mail`) with
  strict timeouts and memory limits. See [doc/SANDBOX.md](doc/SANDBOX.md).
- **Requester inbox & deadlines:** Statutory working-day deadlines, overdue
  reminders, EIR extensions, regulator packs, refusal-advice guidance, and
  voluntary classification.
- **Topics, authority groups & feeds:** Database-managed topic pages and
  datasets, authority groups, FOI statistics, and regulator decision feeds.
- **Core help engine & theming:** Theme-optional neutral UI (Propshaft, Dart
  Sass, Stimulus, Turbo Drive — no jQuery or Bootstrap) plus a Markdown/YAML
  help-pack engine served at `/help`.
- **Optional external integrations:** Reply reading (`IncomingAttention`) and
  hidden-content name checking (`Disclosures::PiiCheck`, e.g. with the open
  [HMC83/name-detector-32m-cells](https://huggingface.co/HMC83/name-detector-32m-cells)
  model or Presidio) are optional contracts disabled by default.

## Quick Start (Docker)

The quickest way to explore Nedervetil locally is with Docker Compose and the
companion MIT-licensed demo theme
([FOIMonkey/nedervetil-test-theme](https://github.com/FOIMonkey/nedervetil-test-theme)):

```sh
git clone https://github.com/FOIMonkey/nedervetil-app.git
cd nedervetil-app
./docker/setup
./docker/server -d
```

Then open:

- **App:** http://localhost:3000
- **Captured mail (MailHog):** http://localhost:1080

To run with core's neutral theme and no external theme repository:

```sh
NO_THEME=1 ./docker/setup
./docker/server -d
```

See [docker/README.md](docker/README.md) for sample accounts, two-factor setup
for admin accounts, resetting the database, and running the parallel spec suite
(`docker/specs`).

## Documentation

- [doc/STACK.md](doc/STACK.md) — runtime, database, queues, auth, and asset stack
- [doc/FORK.md](doc/FORK.md) — fork design notes and inherited file contracts
- [doc/SANDBOX.md](doc/SANDBOX.md) — bubblewrap + seccomp-BPF converter sandbox
- [doc/THEME-ASSETS-UPGRADE.md](doc/THEME-ASSETS-UPGRADE.md) — building themes with Propshaft and Dart Sass
- [docker/README.md](docker/README.md) — local Docker quick start and spec runner

## Checks & Tests

```sh
bin/ci           # RuboCop (Lint/Metrics/Rails/Security/Performance), Zeitwerk, dead_code, bundler-audit, importmap audit, Brakeman
docker/specs     # Parallel RSpec suite in isolated test containers
```

## Licence & Attribution

Nedervetil is licensed under the **GNU Affero General Public License v3.0**
([LICENSE.txt](LICENSE.txt)). It is derived from
[Alaveteli](https://github.com/mysociety/alaveteli) by
[mySociety](https://www.mysociety.org/).

### Upstream Acknowledgements

Full upstream Alaveteli git history and commit authorship are preserved up to
commit `6f671199e` (30 September 2026). This fork also incorporates later
upstream fixes from `mysociety/alaveteli`, with credit to their original
authors:

- **Graeme Porteous** — `0.46.8.0` `fetch_url!` / `Net::HTTP` holiday feed
  import fixes (`Icalendar::Parser::ParseError` handling and removal of
  `URI.open`), fixing attachment text extraction skipping later attachments,
  the `pstore 0.3.0` path spec fix, fixing orphaned mail-server-log search
  documents (`9716`), and immediate purging of unattached blobs stripped from
  ActionText fields (`0.47.0.0`).
- **Gareth Rees** — `0.46.8.0` holiday import HTTP/HTTPS URL validation, POST
  preview, and `fetch_url!` redirect handling; masking incoming message
  subjects in quoted-only body fallbacks (`IncomingMessage#safe_subject`); and
  upstream `develop` refinements to reverting a reported request (`eeeb055bb`).
- **Laurent Savaëte** — preventing attachment unlocking when the underlying raw
  email is absent (`15f1820b9`, incorporated prior to the move to one-file
  storage), the upstream `develop` design for reverting a reported request
  (`69ed931b1`), and upstream `pg_trgm` trigram similarity search branch work
  used for authority name typo fallback.
