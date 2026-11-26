# Stack Overview

| Layer | Technology |
| --- | --- |
| Runtime & framework | Ruby (`.ruby-version`, currently 3.4.13), Rails 8.1, Puma 8 |
| Database & search | PostgreSQL 17/18 (`pg`, full-text + `pg_trgm` search; no Xapian) |
| Background jobs & cache | Sidekiq 8 on Redis (`default`, `low`, `documents`, `incoming_attention`), Memcached for fragment caching and Rails `rate_limit` counters |
| Authentication | Devise 5 + `devise-two-factor` 6, mandatory TOTP 2FA for admins, Active Record Encryption (`support_unencrypted_data = false`), optional Cloudflare Turnstile |
| File storage | Active Storage (local Disk or S3-compatible via `aws-sdk-s3`); single stored blob per `FoiAttachment` |
| Frontend & assets | Propshaft, Dart Sass (`dartsass-rails`), Importmap, Stimulus, Turbo Drive on public pages (`Turbo.session.drive = false` on `/admin` with Turbo Frames); no jQuery or Bootstrap |
| Document conversion & redaction | Bubblewrap + classic seccomp-BPF converter cells (`pdf`, `office`, `mail`) using Poppler, qpdf, pdftk, ImageMagick 7, Tesseract, LibreOffice, `tnef`, `msgconvert`, and standalone `gems/pdf_redactor` / `gems/office_package` workers |
| Optional external services | Off by default: optional self-hosted PII/name checker for hidden Office content (`DISCLOSURES_PII_CHECK` / `DISCLOSURES_PII_CHECK_ENDPOINT`, `badger/v1` or Presidio) and optional reply-reading service (`INCOMING_ATTENTION_*`) |

## Sidekiq Queues

Configure Sidekiq workers to listen on all four queues defined in
`config/sidekiq.yml-example`:

- `default` — general application jobs
- `low` — lower-priority maintenance and indexing jobs
- `documents` — document conversion, masking, preview, and redaction jobs
- `incoming_attention` — optional automated reply-reading jobs

## Theme Independence

Core runs cleanly with `THEME_URLS: []` using neutral design tokens, fallback
help pages, and core's Bootstrap-free admin layout. Themes (such as
[FOIMonkey/nedervetil-test-theme](https://github.com/FOIMonkey/nedervetil-test-theme))
layer visual design, copy overrides, help packs, and jurisdiction data on top.
