# Converter Isolation & Native Worker Contract

Nedervetil runs external document and email converters (`qpdf`, `fix-qdf`, `pdftotext`, `pdftoppm`, `pdfinfo`, `pdffonts`, `pdfimages`, `pdfdetach`, `pdftk`, `magick`, `tesseract`, `elinks`, `libreoffice`/`soffice`, `tnef`, `msgconvert`) and three isolated Ruby workers (`script/pdf_redactor_worker.rb`, `script/office_worker.rb`, `script/mail_worker.rb`) inside bounded `AlaveteliSandbox::Job` sandboxes.

## Modes

Configure converter isolation in `config/general.yml`:

* `SANDBOX_CONVERTERS: 'off'` — development/test default; runs tools directly without bubblewrap. Outside `development` and `test`, `ConverterSandboxCheck.verify!` refuses to boot unless `SANDBOX_CONVERTERS: 'required'`.
* `SANDBOX_CONVERTERS: 'required'` — every conversion runs inside `bubblewrap` (`--unshare-all --unshare-user --disable-userns --die-with-parent --new-session --clearenv`) with classic seccomp-BPF, read-only `/usr`, no network, and `prlimit` memory/CPU/file-size/FD/process caps. Conversions fail closed and never fall back unsandboxed.
* `CONVERTERS_DISABLED: true` — emergency kill switch that stops all external conversions while keeping the site running.

## Conversion Volume (`SANDBOX_VOLUME`)

Mount a dedicated `tmpfs` at `SANDBOX_VOLUME` (default `/run/alaveteli-convert`) with `nosuid,nodev,noexec`:

* Single-process sandbox mode (no cells): owned by the app user, mode `0700`.
* Converter-cell mode: owned by the app user, shared with a group containing only the app user and the three cell users, mode `0710`.

## Dedicated Converter Cells (`script/sandbox_cell.rb`)

To keep native parsers and their toolchains out of the web/Sidekiq user entirely, run three UNIX-socket cell services using `script/sandbox_cell.rb`:

| Cell (`SANDBOX_CELL_KIND`) | Setting | Tools / Worker | Extra env |
| --- | --- | --- | --- |
| `pdf` | `SANDBOX_PDF_CELL` | `pdftotext`, `pdftoppm`, `pdfinfo`, `pdffonts`, `pdfimages`, `pdfdetach`, `pdftk`, `qpdf`, `fix-qdf`, `magick`, `tesseract`, `elinks`, `script/pdf_redactor_worker.rb` | Requires `lib/alaveteli_sandbox/imagemagick-policy.xml` installed as the system ImageMagick policy |
| `office` | `SANDBOX_OFFICE_CELL` | `soffice`/`libreoffice`, `script/office_worker.rb` | `SANDBOX_OFFICE_GEMS` (printed by `script/office_worker_gems`) |
| `mail` | `SANDBOX_MAIL_CELL` | `tnef`, `msgconvert`, `script/mail_worker.rb` | `SANDBOX_MAIL_GEMS` (printed by `script/mail_worker_gems`) |

Required environment variables for each cell service:

* `SANDBOX_CELL_KIND` (`pdf`, `office`, or `mail`)
* `SANDBOX_CELL_SOCKET` (path to the UNIX domain socket)
* `SANDBOX_VOLUME` (shared tmpfs mount path)
* `SANDBOX_BWRAP` (default `/usr/bin/bwrap`)
* `SANDBOX_OFFICE_GEMS` (for `office`) / `SANDBOX_MAIL_GEMS` (for `mail`)

Set all three `SANDBOX_*_CELL` sockets or none. At boot, both the app and each cell hash `AlaveteliSandbox::Cell::SHARED_CODE` and the worker source/gem list; a cell refuses requests from an app running a different release digest until both are restarted.

## Native Tool & ImageMagick Policy Requirements

Install the native binaries under `/usr/bin` (the sandbox only mounts `/usr` read-only):

* `bubblewrap`, `util-linux` (`prlimit`)
* `poppler-utils`, `qpdf`, `pdftk-java` (or `pdftk`), `imagemagick`, `tesseract-ocr`, `elinks`
* `libreoffice-core` / `libreoffice-writer` / `libreoffice-calc` / `libreoffice-impress`
* `tnef`, `libemail-outlook-message-perl` (`msgconvert`)

Install `lib/alaveteli_sandbox/imagemagick-policy.xml` as `/etc/ImageMagick-7/policy.xml` (or `/etc/ImageMagick-6/policy.xml`). The PDF cell checks `magick -list policy` inside the sandbox at startup and refuses to serve if delegates or non-allowlisted coders are enabled.

## Verification & Health Checks

Run the end-to-end sandbox self-test against the live configuration:

```sh
bin/rails sandbox:check
```

`sandbox:check` verifies mode, kill switch, configuration, tmpfs volume permissions, kernel userns sysctls (or cell sockets), ImageMagick policy, and real self-tests for PDF (`PDFRedactor::Isolated.self_test`), Office (`OfficePackage::Isolated.self_test`), Outlook (`MailHandler.outlook_self_test`), and Mail (`MailHandler::Reading.self_test`).

The same four worker self-tests are exposed via `/health/checks` (`PDFMaskingCheck`, `OfficeWorkerCheck`, `OutlookConversionCheck`, `MailReadCheck`), each cached for 1 minute.
