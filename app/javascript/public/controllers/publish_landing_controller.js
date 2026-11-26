import { Controller } from "@hotwired/stimulus"

// Session key set by publish_wait_controller before reloading so the destination page focuses h1.
export const LANDED_KEY = "publish-landed"

export function land() {
  const heading = document.querySelector("#content h1")
  if (!heading) { return }
  heading.setAttribute("tabindex", "-1")
  heading.focus()
}

export default class extends Controller {
  connect() {
    let landed = false
    try {
      landed = window.sessionStorage.getItem(LANDED_KEY) === "1"
      window.sessionStorage.removeItem(LANDED_KEY)
    } catch (_) { /* storage unavailable: nothing to land from */ }
    // A page still waiting stays put; the step after it lands.
    if (landed && !document.querySelector("[data-publish-wait]")) { land() }
  }
}
