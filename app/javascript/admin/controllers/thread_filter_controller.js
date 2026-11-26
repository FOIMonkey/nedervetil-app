import { Controller } from "@hotwired/stimulus"

// Filters the unified chronological Request #show thread between All,
// Messages only, and Events only. Everything stays visible when JS is off.
export default class extends Controller {
  static targets = ["button", "item"]

  filter(event) {
    const mode = event.currentTarget.dataset.filterMode || "all"
    this.buttonTargets.forEach((btn) => {
      btn.setAttribute("aria-pressed", btn.dataset.filterMode === mode ? "true" : "false")
    })
    this.itemTargets.forEach((el) => {
      const kind = el.dataset.threadKind
      const show = mode === "all" ||
        (mode === "messages" && (kind === "outgoing" || kind === "incoming")) ||
        (mode === "events" && kind === "event")
      el.hidden = !show
    })
  }
}
