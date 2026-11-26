import { Controller } from "@hotwired/stimulus"
import { fromCache } from "helpers/turbo_cache"
import { openAround } from "helpers/open_details"

// Opens and focuses hash-targeted requester feed rows (also handles repeated clicks on the same hash).
export default class extends Controller {
  connect() {
    // Preserve cached row state and browser focus on Back/Forward restore.
    if (fromCache()) { return }
    // After the browser's own jump to the fragment, which clears focus.
    this.onLoad = () => window.setTimeout(() => this.landed(), 0)
    if (document.readyState === "complete") {
      this.onLoad()
    } else {
      window.addEventListener("load", this.onLoad, { once: true })
    }
  }

  disconnect() {
    if (this.onLoad) { window.removeEventListener("load", this.onLoad) }
  }

  // Open the target row without stealing focus when a flash notice is present (flash-focus handles it).
  landed() {
    this.open(!document.querySelector(".requester-view .band-flash"))
  }

  click(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey) { return }
    const link = event.target.closest && event.target.closest('a[href^="#"]')
    if (link && link.getAttribute("href").length > 1 && link.hash === window.location.hash) {
      event.preventDefault()
      this.open(true)
    }
  }

  fromHash() {
    this.open(true)
  }

  open(focus) {
    let id
    try { id = decodeURIComponent(window.location.hash.slice(1)) } catch (_) { return }
    if (id) { this.reveal(id, focus) }
  }

  reveal(id, focus) {
    const target = document.getElementById(id)
    if (!target || !this.element.contains(target)) { return }
    openAround(target)
    if (!focus) { return }
    const spot = target.matches("details") ? target.querySelector("summary") : target
    if (spot !== target || target.matches("a, button, input, summary")) {
      spot.focus()
    } else {
      target.setAttribute("tabindex", "-1")
      target.focus()
    }
    target.scrollIntoView()
  }
}
