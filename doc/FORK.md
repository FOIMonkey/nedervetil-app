# Fork Guide

Nedervetil (`FOIMonkey/nedervetil-app`) is an AGPL-3.0 fork of Alaveteli built around **private-by-default Freedom of Information requests** and a **separate, reviewed public documents catalogue**.

This guide records how Nedervetil deliberately diverges from upstream Alaveteli and which architectural contracts must be preserved when importing upstream changes or operating an instance.

Related documentation:

* [`STACK.md`](STACK.md) — runtime, database, Sidekiq queues, authentication, and asset stack
* [`SANDBOX.md`](SANDBOX.md) — bubblewrap + seccomp-BPF converter cells and native tool requirements
* [`THEME-ASSETS-UPGRADE.md`](THEME-ASSETS-UPGRADE.md) — building themes with Propshaft and Dart Sass
* [`../docker/README.md`](../docker/README.md) — Docker quick start, sample data, and parallel spec runner

---

## Overview & Core Privacy Policy

Request correspondence (outgoing letters, authority replies, attachments, and account details) is private to the requester and authorised administrators. Public disclosure happens through a separate, reviewed catalogue of `Disclosures::Document` records rather than by publishing request threads.

`PrivateArchive::Policy` defines fixed core-model policy overrides. These are product decisions rather than toggleable feature flags:

* **Requester-only requests:** `InfoRequest` defaults to `prominence: 'requester_only'` and permits only `requester_only` or `hidden` (`InfoRequest::Prominence::VALUES`). Do not restore upstream public values (`normal`, `backpage`).
* **Message & attachment prominence:** `IncomingMessage` and `OutgoingMessage` permit `normal` or `hidden` via `MessageProminence`. `FoiAttachment` permits `public`, `requester_only`, or `hidden` via `FoiAttachment::Prominence` (retiring `'normal'`).
* **Private correspondence vs public documents:** `PrivateArchive::Policy.searchable_options` places all `InfoRequest` and `OutgoingMessage` fields exclusively in `admin_index` (`raw_admin_content` / `admin_content_tsv`), so private correspondence never enters public search or bulk `reindex_all`. `User` and `InfoRequestEvent` remain admin-only. Published documents are indexed separately in their own catalogue.
* **Fail-closed HTTP & storage gates:**
  * The `PrivateArchive` concern runs ahead of controller actions in `ApplicationController`, sets `Cache-Control: private, no-store`, and returns `404` for unauthorised requests, batches, user profiles, request events, attachments, attachment masks, and outgoing delivery statuses.
  * `PrivateArchive::StoragePolicy` (`config/initializers/private_archive.rb`) denies direct `ActiveStorage::BaseController` signed blob and disk URLs with `404`.
* **CanCanCan abilities:** `Ability` splits read rules across `VisitorRules`, `RequesterRules`, and `AdminRules`, backed by `Ability::RequesterVisible` (allow-list prominence evaluation in both Ruby and SQL). Suspended or closed administrators lose all admin powers (`User#active_admin?`).
* **Unified account experience:** Every signed-in account uses the unified inbox under `/pro/*`. Pro roles (`pro`, `pro_admin`), Stripe billing, and `rolify` are removed. `User#trusted?` (replacing `no_limit` and `can_make_batch_requests`) governs sending-limit exemptions and batch requests, with admin permission changes logged in `User::PermissionChange`.
* **Closed public surfaces:** Public sharing tokens (`/r/*`), legacy feeds and tracking (`/feed/*`, `/track/*`), user walls and contact pages, `/api/v2/*`, and private counts in `/version.json` are closed. Legacy `/search` routes redirect to `/documents`, and public pages avoid setting a default locale cookie.

---

## Runtime, Dependencies & Security Initializers

See [`STACK.md`](STACK.md) for the full technology summary and Sidekiq queue layout (`default`, `low`, `documents`, `incoming_attention`).

* **Runtime & framework:** Pins Ruby in `.ruby-version` (currently `3.4.13`), Rails `8.1` (`config.load_defaults 8.1`), Puma `8`, Rack `3.2`, Sidekiq `8` (using `redis-client` rather than legacy `redis`), PostgreSQL (`pg`, `max_connections` in `config/database.yml-example`), and `bootsnap`. `StripEmptySessions` and `DeeplyNestedParams` preserve Rack 3 lowercase headers and array-safe `set-cookie` handling.
* **Background jobs:** Uses `activejob-unique` for Rails 8.1 compatibility and orders `retry_on ActiveRecord::Deadlocked` after `retry_on StandardError` in `ApplicationJob` so deadlocks use their dedicated retry handler.
* **Vendored mySociety helpers:** The `commonlib` git submodule is replaced by the minimal vendored subset in [`vendor/mysociety/`](../vendor/mysociety/README.md) alongside pure-Ruby `AsciiText` (`lib/ascii_text.rb`), allowing a fresh clone to boot with no submodules.
* **ZIP streaming, versioning & dependencies:** Batch ZIP exports use `zip_kit` instead of `zip_tricks`. `PublicBody::Versioned` replaces `acts_as_versioned`, and `countries` replaces `iso_country_codes`. Core HTML/XML/auth dependencies (`loofah`, `rails-html-sanitizer`, `nokogiri`, `cancancan`, `mail`, `dalli`, `net-http`) are kept on patched releases, with `brakeman` and `bundler-audit` included in development and test.
* **Schema precision, locales & test setup:** All database timestamps use precision 6. `locale/` and `locale_alaveteli_pro/` are trimmed to maintained English and Welsh catalogues. `config/storage.yml-example` scopes test storage paths by `TEST_ENV_NUMBER`, and `config/environments/test.rb` enables `config.yjit = true`.
* **Security initializers & core hardening contracts:**
  * `config/initializers/filter_parameter_logging.rb` keeps `:email` in Rails' filtered log parameters (do not import upstream's removal of `:email`).
  * `config/initializers/action_view.rb` excludes `html`, `head`, `body`, and `style` from the Action View HTML sanitiser allowlist.
  * `config/initializers/secure_headers.rb` drops the deprecated `X-XSS-Protection` header, delegates HSTS to `force_ssl` / reverse proxy, and defines the `:authentication` (`strict-origin`) referrer-policy override.
  * `lib/core_ext/action_text_without_attachments.rb` (`ActionText::WithoutAttachments`) provides `has_rich_text_without_attachments`, stripping embedded ActionText attachments on every validation and save path and immediately queueing unattached stripped blobs for purge (`purge_later` when `blob.attachments.none?`).
  * `config/initializers/content_security_policy.rb` enforces `script-src 'self' 'strict-dynamic'` with per-request nonces; `app/javascript/helpers/turbo_script_guard.js` blocks unnonced `<script>` tags across Turbo Drive, Turbo Frame, and Turbo Stream renders.
  * `gems/alaveteli_features` makes `with_actor` return an isolated copy rather than mutating shared feature objects across threads.
  * `ProductionSafety` (`config/initializers/production_safety.rb`) refuses boot in production with default or short secrets or with `SKIP_ADMIN_AUTH` enabled.

---

## Assets, Frontend & Theme Independence

See [`THEME-ASSETS-UPGRADE.md`](THEME-ASSETS-UPGRADE.md) for theme authoring and asset-override conventions.

* **Propshaft & Dart Sass:** Replaces Sprockets 3, `sass-rails`, `bootstrap-sass`, `jquery-rails`, `jquery-ui-rails`, and `fancybox-rails` with `propshaft` and `dartsass-rails`. Stylesheets use Dart Sass `@use` modules (`app/assets/stylesheets/`) and compile per active theme set into `app/assets/builds/<themes>` (`config/initializers/assets.rb`, `config/initializers/theme_loader.rb`). `bin/dev` builds and watches stylesheets alongside Rails.
* **Importmap, Stimulus & Turbo:**
  * Public pages load Stimulus and Turbo Drive via `config/importmap.rb` (`javascript_importmap_tags("public")`).
  * Admin pages load a dedicated importmap (`config/importmaps/admin.rb`, `config/initializers/admin_importmap.rb`) with `Turbo.session.drive = false` so `<turbo-frame>` works while full admin navigations always perform full page loads.
  * Body-level Stimulus controllers (`confirm`, `method-link`, `form-lock`) replace jQuery UJS. `announcement-dismiss` paired with `button_to` replaces jQuery `remote: true`.
  * `TurboDrive` provides per-controller and per-action `turbo_drive false` opt-outs and `keep_no_turbo_copy!`. Signed-in pages always emit `turbo-cache-control: no-cache` so browser Back never restores private pages from Turbo's client cache.
  * Headless Chromium system specs run via Cuprite (`spec/support/javascript_driver.rb`, `js: true`) and fail on any JavaScript error.
* **Neutral no-theme default & local Trix:** Core supplies neutral design tokens (`responsive/features/tokens`) and its own Bootstrap-free admin stylesheet (`admin.scss`), so the application runs cleanly with `THEME_URLS: []`. Trix is vendored locally in `vendor/assets/javascripts/trix.js` rather than loaded from a CDN.

---

## Authentication, 2FA & Draft Handoff

* **Devise 5 & `devise-two-factor` 6:** Replaces upstream custom password and OTP handling (`config/initializers/devise.rb`, `User::Authentication`). Active Record Encryption keeps `support_unencrypted_data = false` so plaintext OTP secrets fail closed.
* **Mandatory admin 2FA & no emergency login:** `AdminController` and `AdminConstraint` enforce `Authentication::Session.admin?(request)` (an active admin with enrolled TOTP). Legacy emergency login (`?emergency=1`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`) has been removed.
* **Password-on-confirmation & 2FA-checked resets:** Sign-up collects name and email only; the confirmation link sets the password. Password resets for accounts with 2FA require a valid TOTP or recovery code verified inside a savepoint and accounts never auto-sign-in.
* **Encrypted draft handoff & bounded returns:** Signed-out request drafts travel via `PendingRequestDraft` (encrypted payload, single-use transfer token, 30-minute TTL, bound to the authenticated account). Sign-in redirects are bounded by `AuthenticationReturn` and `Authentication::ReturnPath`.
* **Origin checks, rate limits & Turnstile:**
  * `SigningIn#verify_signed_out_origin` enforces same-origin `Origin`/`Referer` checks on signed-out mutations.
  * Authentication controllers enforce Rails `rate_limit` (backed by Memcached), rendering `general/too_many_attempts` on HTTP 429.
  * `Turnstile` / `TurnstileCheck` (`TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY`) protects sign-ups, first requests, and signed-out contact/change-request forms, failing closed outside development and test.

---

## PostgreSQL Search

* **PostgreSQL-only index (no Xapian):** Builds on upstream Alaveteli's PostgreSQL search foundation (`search_documents` partitioned table, `Searchable`, `SearchDocument`, `Search::Adapters::Postgresql::Adapter` with materialised CTEs and ranking) and removes Xapian (`xapian-full-alaveteli`, `acts_as_xapian`, `acts_as_xapian_jobs`, scripts, and health/metric checks) completely so PostgreSQL is the sole search backend.
* **Authority-only typeahead with typo fallback:** `Search.typeahead` serves `PublicBody` lookups only (`AuthorityQuery`, plus `SimilarNameQuery` over `public_body_translations.name` using `pg_trgm` word similarity adapted from upstream `pg_trgm` branch work), normalising apostrophes (`Searchable.without_apostrophes`), ranking all-term proximity matches first, and excluding tagged authorities (`exclude_tags`) before counting.
* **Composable scoped search:** `Model.search_scope(query, **options)` (or `Search.search_scope`) returns a chainable `ActiveRecord::Relation` that composes with permission scopes, filters, and pagination across admin listings.
* **Private-archive search boundary:** `InfoRequest` and `OutgoingMessage` index solely into `admin_index` via `PrivateArchive::Policy.searchable_options`, ensuring private correspondence never enters public search results. Published documents are searched separately through `Disclosures::Search`.

---

## Document Processing, Redaction & Converter Sandbox

See [`SANDBOX.md`](SANDBOX.md) for `AlaveteliSandbox::Job`, bubblewrap + seccomp-BPF modes (`SANDBOX_CONVERTERS`, `CONVERTERS_DISABLED`), `SANDBOX_VOLUME`, dedicated converter cells (`SANDBOX_PDF_CELL`, `SANDBOX_OFFICE_CELL`, `SANDBOX_MAIL_CELL`), native tool requirements, ImageMagick policy, and `bin/rails sandbox:check`.

* **Standalone document libraries (no runtime Rails dependency):**
  * `gems/pdf_redactor` (`PDFRedactor`): reads, surveys, and visibly redacts PDF text, embedded images, and metadata within strict size, recursion, and object bounds. Runs out of process via `PDFRedactor::Isolated` (`script/pdf_redactor_worker.rb`).
  * `gems/office_package` (`OfficePackage`): bounded OOXML/ZIP inspection, compound-file (`.msg`/`.xls`) reading, hidden-content detection, spreadsheet cell reading, and metadata tidying (replacing `rubyXL`). Runs out of process via `OfficePackage::Isolated` (`script/office_worker.rb`).
  * `gems/excel_analyzer` (`ExcelAnalyzer`): Active Storage analysers for `.xlsx`/`.xlsm`/`.xltx`/`.xltm`, `.xls`/`.xlsb`, `.zip` archives, embedded Office spreadsheets (`.docx`/`.pptx`), and `.eml` attachments backed by `OfficePackage::ExcelMetadata` (removing `rubyXL`).
* **Sandboxed converter dispatch & boot guards:**
  * `ConverterSandboxCheck` refuses boot outside development and test unless `SANDBOX_CONVERTERS: 'required'`. Conversions fail closed and never fall back unsandboxed.
  * `MailHandler` drops legacy `ruby-msg` in favour of `OfficePackage::CompoundFile`, sandboxed `msgconvert`/`tnef`, and `MailHandler::Reading` (`script/mail_worker.rb`).
  * `AttachmentToText` runs inside bounded sandbox jobs (extracting RTF via LibreOffice rather than UnRTF). Maskable formats (PDF, HTML) raise `AttachmentToText::ConversionFailed` on failure so `IncomingMessage::MainBody` retries rather than caching empty text; zip-based Office formats return empty text.
  * `/health/checks` monitors `PDFMaskingCheck`, `OfficeWorkerCheck`, `OutlookConversionCheck`, and `MailReadCheck`.
* **Async reply parsing & 120-day `RawEmail` retention:**
  * `IncomingMessage` stores header values on receipt, serialises parses through Active Storage uploads via `IncomingMessage::ParsingLock`, populates main-body text asynchronously via `IncomingMessage::StoreTextJob`, normalises Outlook HTML tables (`EmailTables`), and re-queues refused mail reads in `RequestMailbox`.
  * `RawEmail` tracks `read_at`, removes Action Mailbox's duplicate `InboundEmail` via `RawEmail::ForgetInboundJob`, and expires raw emails after `RawEmail::KEPT_FOR` (120 days of request inactivity).
* **One-file `FoiAttachment` storage, shared attachment primitives & fail-closed masking:**
  * Each `FoiAttachment` owns a single Active Storage file (`FoiAttachment::StoredFile`, `Prominence`, `Erasable`, `Maskable`) and purges its blob once on destroy.
  * Shared attachment checks and content readers live under `FoiAttachment` (`FoiAttachment::Content`, `FoiAttachment::LetterPick`, `FoiAttachment::Ocr`, `FoiAttachment::SpreadsheetHold`, `FoiAttachment::SpreadsheetCheckJob`) so visibility, reply reading, Excel analysis, and disclosure suggestions use the same lower-layer primitives directly.
  * `CensorRule` supports `black` (requester-reaching) and `blue` (public-only) rules plus `masking_finished_at`. `InfoRequest::Masking` and `MaskSet` compute per-view mask sets.
  * Masking runs in place on `FoiAttachment#file` and never reads `RawEmail` during normal masking (only on explicit `remask_from_email!`). `AlaveteliTextMasker` routes PDF masking through `PDFRedactor`, leaves zip/archive containers uncorrupted by skipping byte masking, and fails closed on masking faults by setting `masking_failed_at` (refused on every public path).
* **Working-copy redaction editor (`AttachmentManagement`):**
  * Requesters and admins redact PDFs (visual box and word tools), edit reply text, or replace files via isolated `AttachmentManagement::Revision` drafts and `AttachmentManagement::ProcessJob` on the `documents` queue, applying edits atomically through `AttachmentManagement::Replacement` with `AttachmentManagement::ZipGuard` safety checks.
  * Configured via `ATTACHMENT_MANAGEMENT_REQUESTER_ACCESS`, `ATTACHMENT_MANAGEMENT_DRAFT_HOURS`, and `ATTACHMENT_MANAGEMENT_PREVIEW_HOURS` in [`config/general.yml-example`](../config/general.yml-example).
* **Controlled publication (`Disclosures`) & Office hidden-content holds:**
  * Attachments remain `requester_only` until explicitly prepared, checked, and published as `Disclosures::Document` records with 12-character public IDs, rendered page PNGs, and OCR-extracted searchable text.
  * Pre-publish checks run `Disclosures::RuleCheck`, `Disclosures::HiddenRisk`, and optional `PiiCheck` (disabled by default via `DISCLOSURES_PII_CHECK: 'off'`, failing closed to `:unavailable` when enabled and unreachable).
  * Supports an optional admin review queue (`Disclosures::ReviewSubmission`, `/documents/review`), withdrawal and erasure, and request deletion that keeps published documents detached from private correspondence.
  * `config/initializers/excel_analyzer.rb` routes `ExcelAnalyzer` through `OfficePackage::Isolated` and `AttachmentManagement::ZipGuard`, holds spreadsheets and embedded Office files with hidden rows, columns, sheets, or comments via `FoiAttachment::SpreadsheetHold`, and discards `AlaveteliSandbox::Refused` on `ActiveStorage::AnalyzeJob` so `FoiAttachment::SpreadsheetCheckJob` owns deferred retries while unanalysed blobs remain held.
  * Configured via `DISCLOSURES_*` settings in [`config/general.yml-example`](../config/general.yml-example).

---

## Request Lifecycle, Deadlines & Optional Reply Reading

* **Unified request journey (`RequestJourney`):**
  * Signed-in accounts draft, preview, and send requests through the step-by-step inbox flow (`RequestJourney::ProRequestSteps`, `RequestJourney::Review`, `RequestJourney::Checks`, `RequestJourney::Suggestions`, `RequestLetter`, `RequestJourney::NavigationHelper`), with `DraftInfoRequest` storing `journey_context`.
  * Signed-out visitors start anonymously and hand off into an owned inbox draft on sign-in (`PendingRequestDraft`). Sending requires a signed review token matching the current draft fingerprint.
  * `OutgoingMessage::DeliveryTransitions` updates request state under row locks on delivery failures and follow-up resends without consuming unread replies.
  * `InfoRequest.find_existing` scopes duplicate checks to the caller's own requests (`within:`), and `NewRequestChecks` runs spam-term and first-request Turnstile checks.
* **Append-only request & batch limits (`RequestLimits`):**
  * `request_limit_sends` (`RequestLimits::Send`) logs requests and follow-ups inside the creating transaction under row-locked (`FOR NO KEY UPDATE`) atomic quota checks (1 request/minute, 3/24 hours, 10/30 days; 25 follow-ups/30 days, 3/5 minutes per request), so deleting a request does not reclaim quota.
  * Enforces batch authority caps (`RequestLimits::BATCH_AUTHORITIES = 50`), trusted-account exemptions (`User#trusted?`, `Ability#sending_rules`), and mid-batch permission re-checks (`InfoRequestBatch#user_may_send?`).
  * Controlled by `ENFORCE_REQUEST_LIMITS` (default `true` in production; `REQUEST_LIMITS=on` outside production).
* **Statutory working-day deadlines & requester workspace (`Deadlines`):**
  * Computes working-day response, clarification, and review deadlines across statutory regimes (`Deadlines::Law`, `Deadlines::Calendar`, `Holiday`, `ThemeData` bank holidays), supporting requester deadline adjustments, voluntary closure, and overdue reminder tracking.
  * `WORKING_OR_CALENDAR_DAYS: working` is the only supported request setting; `Deadlines::Calendar.validate_configuration!` raises `Deadlines::Calendar::UnsupportedCalendar` otherwise.
  * The requester request view and action-driven inbox (`Deadlines::Overview`, `Deadlines::Piles`, `Deadlines::NextAction`) present a status band, next-step prompt, receipt card, newest-first correspondence timeline, and batch-loaded action piles (`needs`, `waiting`, `finished`) on `/pro/dashboard` and `/pro/info_requests`.
* **Regulator packs, refusal advice & core `under_appeal` status:**
  * `RegulatorPack` / `RegulatorPacksController` / `InfoRequest::RegulatorPackJob` builds downloadable request ZIP archives asynchronously with signed 48-hour tokens, applying black censor rules and purging stale packs when attachments change or publish.
  * `RefusalAdvice` (`refusal_wizard_controller.js` and the `ClassificationRefusal` authorisation guard) provides structured refusal guidance.
  * `under_appeal` is a first-class core `InfoRequest::State` (valid state, owner transition, status text, and `:other` phase) independent of theme custom-state hooks.
* **Optional reply reading (`IncomingAttention`, disabled by default):**
  * Controlled by `INCOMING_ATTENTION_ENABLED: false` (default) and `INCOMING_OUTCOME_MODE` (`off`/`shadow`/`apply`).
  * When enabled, sends masked, bounded reply payloads through `IncomingAttention::Transport` and `IncomingAttention::Client` to a configured HTTPS `/v1/classify` endpoint (optionally via an anonymiser proxy `INCOMING_ATTENTION_ANONYMISER_ENDPOINT`, with auth tokens passed via environment variables), with no external worker code embedded in core.
  * Supports per-account opt-out at `/profile/ai_reading` and stale-check recovery via `IncomingAttention::Recovery` (`lib/tasks/incoming_attention.rake`).
  * Automatic outcome application runs via `IncomingAttention::Classification.automatically` (`Current.automatic_classification`), never overwrites manual classifications, invalidates stale predictions when request visibility or attachments change, and lets requesters confirm, dismiss, or override readings on the request page (`IncomingAttention::ChoicesController`).
* **Daily summary vs instant emails (`IncomingAttention::Digest`, `IncomingAttention::InstantEmails`):**
  * Accounts receive a daily summary by default and can opt into instant per-reply emails at `/profile/emails`.
  * `NotificationMailer` and `IncomingAttention::Digest` hold routine-only daily digests until the account's next summary time, deliver holding-pen admin alerts immediately without digest enrolment, and expose `IncomingAttention::Digest.deliverable?` as a neutral extension hook.

---

## Topics, Authority Groups, Feeds & Public Documents Catalogue

* **Database-managed topics & guides (`Topics`, `TopicPage`, `TopicGuide`):**
  * Stores topics, questions, holders, datasets, sources, routes, and guides in PostgreSQL with reference validation (`TopicLinkValidator`, `TopicNationsValidator`, `TopicUrlValidator`) and audit logging (`TopicChange`).
  * Serves `/`, `/topics`, `/topics/:slug`, `/topics/:slug/who-holds-it`, and `/topics/:slug/:question`, with invented demo topics provided by `SampleData::Topics`.
  * Admin CRUD (`Admin::Topic*Controller`) manages topic pages, holders, questions, sources, routes, datasets, guides, and audit history under `/admin/topics`, `/admin/datasets`, `/admin/topic_guides`, and `/admin/topic_history` with `Current.user` attribution via `Admin::TopicContentEditing`.
* **Authority groups & external releases (`AuthorityGroups`):**
  * Groups public bodies by category or tag (`/groups`, `/groups/:tag`), renders theme geography maps (`AuthorityGroups::Map`), adds admin-editable one-line descriptions (`AuthorityGroups::WhoLine`), and supports CSV import, review, pinning, and hiding of external proactive releases (`AuthorityGroups::ExternalRelease`, `ReleaseImport`, `ReleaseCsv`).
* **External feeds & FOI statistics (`AuthorityFeeds`, `FoiStatistics`):**
  * Adds authority feed definitions, CSV and remote fetch imports, authority name mappings, link templates, `/body/:url_name/{documents,foi-record}` tabs, and `FoiStatistics` parsing and display.
* **Public documents catalogue & JSON feed (`/documents`, `/documents.json`, `/body/:url_name`):**
  * Full-text and facet search over published `Disclosures::Document` records (`Disclosures::Search`), authority-grouped answers, pagination- and concurrency-safe JSON publication feed (`/documents.json`), `Disclosures::TopicMatch` automatic topic tagging, and before-send published-document suggestions.
  * Maintains constant-query-count budgets across `/documents`, `/body/:url_name`, and requester pages.

---

## Core Help Engine & Admin Workspace

* **Theme-supplied Markdown/YAML help engine (`HelpSite`, `HelpSiteController`):**
  * Serves `/help`, `/help/:section`, `/help/:section/:answer`, `/help/words`, and JSON search (`/help/search`) from the first loaded theme's `lib/help_site/` pack (`sections.yml`, `answers/<section>/<id>.md`, and optional `glossary.yml`, `signs.yml`, `guide.yml`, and `refusal_reasons.yml`).
  * Falls back cleanly to `app/views/help_site/fallback.html.erb` and legacy `/help/*` views when no theme or help pack is loaded (`THEME_URLS: []`).
  * Includes accessible client-side search (`help_find_controller.js`), glossary term popovers and jumps (`help_words_controller.js`), and `TurnstileCheck` protection on signed-out contact submissions (`HelpController`).
* **Turbo deadline checker (`Deadlines::Checker`):**
  * Renders `app/views/help_site/extras/_date_tool.html.erb` inside help answers declaring `extra: date-tool`, calculating statutory FOI/EIR reply dates across UK jurisdictions and bank holidays inside a Turbo Frame without full-page reloads.
* **Namespaced queue-first `/admin` workspace:**
  * All legacy `admin_*` controllers and `app/views/admin_*` templates are migrated under `Admin::*` (`app/controllers/admin/`, `app/views/admin/`, `app/helpers/admin/`), paired with `app/views/layouts/admin.html.erb` and Stimulus admin controllers (`admin_jump`, `triage_list`, `bulk_select`, `tagging`, `record_picker`, `thread_filter`, `locale_tabs`, `holidays`, `holiday_import`, `category_order`, `note_style`, `previous_comment`).
  * Replaces the legacy admin landing page with a queue-first triage workspace (`/admin`, `/admin/jump`, `/admin/triage/:kind/:id`, `Admin::HoldingPenContext`), constant-query-count review queues, and authority summary panels (`WhoLine`, `What they hold`).

---

## Retired Upstream Surfaces

The following upstream Alaveteli features were intentionally removed (tables dropped; models, controllers, views, routes, gems, and specs deleted) rather than toggled off. Do not restore them when porting upstream changes:

* **Xapian search** (`xapian-full-alaveteli`, `acts_as_xapian`, `acts_as_xapian_jobs`, Xapian scripts, and Xapian health/metric checks)
* **Embargoes** and Pro embargo defaults
* **Stripe billing & Pro monetisation** (Pro pricing/subscriptions, `pro`/`pro_admin` roles, and `rolify`)
* **Comments / annotations**
* **Tracks** (alerts and feeds for followed requests, authorities, people, and searches)
* **Citations** and **Projects**
* **Request widgets** and **Blog posts**
* **Profile photos**, `users.about_me`, and **user-to-user messaging**
* **Public sharing tokens** (`/r/*`), public request/user walls, and `/api/v2/*` JSON mirrors of private correspondence
* **Authority API** (`public_body_api_keys`) and **external requests**
* **UnRTF adapter** and public **"View as HTML"** (`AttachmentToHTML`)
* **Legacy attachment editor recovery drafts**, **Ollama insights**, **public body request counter columns**, and **legacy emergency admin login** (`?emergency=1`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`)

---

## Verification

Run the standard checks before merging changes or after pulling upstream updates:

* **`bin/ci`** — runs RuboCop (`Lint`, `Metrics`, `Rails`, `Security`, `Performance`), `bin/rails zeitwerk:check`, `bin/rails dead_code`, `bin/bundler-audit`, `bin/importmap audit`, and `bin/brakeman`.
* **`bin/rails sandbox:check`** — verifies converter sandbox configuration, `tmpfs` volume permissions, ImageMagick policy, and live PDF, Office, Outlook, and Mail worker self-tests (see [`SANDBOX.md`](SANDBOX.md)).
* **`docker/specs`** — runs the parallel RSpec test suite in isolated database and Redis containers (see [`../docker/README.md`](../docker/README.md)).
