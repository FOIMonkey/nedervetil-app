import "@hotwired/turbo-rails";
import "controllers";
import {
  guardTurboFrameScripts,
  guardTurboStreamScripts
} from "helpers/turbo_script_guard";

// Keep full Turbo Drive off /admin; only <turbo-frame> works for progressive
// enhancement (doc/FORK.md).
Turbo.session.drive = false;
document.addEventListener("turbo:before-frame-render", guardTurboFrameScripts);
document.addEventListener("turbo:before-stream-render", guardTurboStreamScripts);
