# Docker Quick Start

**This Docker environment is intended for local development and evaluation.**

## What the quick start gives you

Clone `nedervetil-app` and run `docker/setup`. Setup creates a sibling
`alaveteli-themes/` directory if it does not already exist and clones the demo
theme into it:

    nedervetil-app/                 https://github.com/FOIMonkey/nedervetil-app
    alaveteli-themes/
      nedervetil-test-theme/        https://github.com/FOIMonkey/nedervetil-test-theme

From the `nedervetil-app` directory, prepare the demo and start it:

    docker/setup
    docker/server -d

Open http://localhost:3000. `docker/server` without `-d` runs the same services
with logs in your terminal. Both start the app and its Sidekiq worker listening
on `default`, `low`, `documents`, and `incoming_attention` (matching
`config/sidekiq.yml-example`), covering document checks, conversions,
redactions, and optional reply reading.

To check services or follow document processing:

    docker compose ps
    docker compose logs -f sidekiq

Stop the demo with `docker compose stop`; its database and files are preserved.

Set `DEMO_THEME_URL` to clone a different theme, or see
[Without a theme](#without-a-theme). Setup writes
`config/general-nedervetil-test-theme.yml` from `config/general.yml-example`
with `SITE_NAME: 'Nedervetil'`, `ENABLE_TWO_FACTOR_AUTH: true`,
`INCOMING_ATTENTION_ENABLED: true`, and `INCOMING_OUTCOME_MODE: 'apply'`, then
links `config/general.yml` to it. `config/general.yml-example` keeps
production's defaults.

The image uses the Ruby version in `.ruby-version` (currently 3.4.13). To build
another, set `APP_RUBY_VERSION`. The app, database, and mail catcher listen on
localhost only: http://localhost:3000 and, for mail, http://localhost:1080.

Setup loads invented sample data (`bin/rails sample_data:load`):

- authorities in groups by place, type, and sector;
- requests across the main lifecycle states, with deadlines, a reminder, and a batch;
- published documents and one redaction waiting in the admin review queue;
- stored AI readings, so no external reply-reading service is needed;
- regulator decisions and FOI statistics.

Requests are private, so sign in to see requester and admin views:

| Account | Email | Password |
| --- | --- | --- |
| Requester | `requester@example.org` | `jonespassword` |
| Admin | `admin@example.org` | `jonespassword` |
| Admin with every role | `annie@localhost` | `jonespassword` |

`bin/rails sample_data:accounts` prints these again. They exist only in the
sample data, which refuses to load in production. Admin accounts require
two-factor authentication: the first time you sign in as `admin@example.org` or
`annie@localhost`, the app walks you through setting up a TOTP authenticator
before opening `/admin`.

Things to try:

- Start a new request to Larkhollow District Council about public toilets. On
  the check step, the site suggests published documents from that council and
  common topic questions.
- Sign in as `admin@example.org`, complete the 2FA setup prompt, and open
  `/documents/review` to inspect the requester's redaction of a decision letter.
- On the requester's dashboard, press Remind on the overdue request. The
  follow-up appears in MailHog at http://localhost:1080.
- Send a daily summary: `docker compose run --rm app script/send-notifications`.

Mail isn't sent while sample data loads, so MailHog starts empty.

Request limits apply only in production, or in development with
`REQUEST_LIMITS=on`. Sample data uses none of an account's allowance.

## Stylesheets

Dart Sass builds stylesheets and Propshaft serves all assets. The app container
runs `bin/dev`, which builds stylesheets and watches for changes. To build once,
run `bin/rails dartsass:build`. Each theme set builds into its own folder in
`app/assets/builds`, so one theme's CSS is never served with another.

## Starting again

`docker/setup --reset-data` loads sample data only into an empty database. To
start fresh, run `docker/reset` and answer `y` to resetting the database.
Databases created with an older PostgreSQL major version also need a reset
because the quick start uses PostgreSQL 18.

## Without a theme

`NO_THEME=1 docker/setup` writes `config/general-none.yml` with `THEME_URLS: []`
and links `config/general.yml` to it (remove any existing `config/general.yml`
first). Sample data loads as usual, using core's neutral theme tokens,
placeholder logo, and fallback help pages.

## Your own themes

List themes in `THEME_URLS` in `config/general.yml` (first listed wins). Setup
switches to the theme named by `config/general-<theme>.yml` and links it into
`lib/themes/`. Link any additional themes manually:

    ln -s ../../../alaveteli-themes/<theme> lib/themes/<theme>

## The converter sandbox

The image includes `bubblewrap` and mounts a tmpfs at `/run/alaveteli-convert`.
The sandbox defaults to off in the example config; set
`SANDBOX_CONVERTERS: 'required'` and run `bin/rails sandbox:check` to verify
it. If Docker's default seccomp/AppArmor profile blocks unprivileged user
namespaces, `sandbox:check` reports that directly.

## Running the specs

`docker/specs` runs the test suite in parallel using dedicated database and
Redis containers (`specs-db`, `specs-redis`), leaving development data
untouched:

    docker/specs                 # full suite
    docker/specs -n 4            # four workers
    docker/specs spec/models     # specific files or folders
    docker/specs --record        # record file timings

Set `COVERAGE=local` for a coverage report in `coverage/`. Stop the spec
services afterwards with `docker compose --profile specs down`.
