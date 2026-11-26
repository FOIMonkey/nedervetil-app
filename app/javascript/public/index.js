// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails";
import "controllers";
import { guardTurboScripts, guardTurboFrameScripts, guardTurboStreamScripts } from "helpers/turbo_script_guard";
import "helpers/turbo_cache";

import { jumpWithinPage } from "helpers/same_page_links";
import { loadInFull } from "helpers/full_load_links";
import "helpers/page_announcer";
import "helpers/morph_refresh";

document.addEventListener("turbo:before-render", guardTurboScripts)
document.addEventListener("turbo:before-frame-render", guardTurboFrameScripts)
document.addEventListener("turbo:before-stream-render", guardTurboStreamScripts)
document.addEventListener("turbo:click", jumpWithinPage)
document.addEventListener("turbo:click", loadInFull)

// Drive is enabled on public pages (except doc/FORK.md opt-outs); admin keeps Drive off.
Turbo.session.drive = true
