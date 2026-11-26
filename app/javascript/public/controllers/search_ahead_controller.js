import { Controller } from "@hotwired/stimulus"

// Debounced Turbo Frame search-ahead; falls back to normal form submission.
export default class extends Controller {
  static targets = ["field", "results"]
  static values = { url: String, param: { type: String, default: "q" }, params: Object, delay: { type: Number, default: 300 }, newTab: Boolean }

  // Clear stale results restored from Turbo cache.
  connect() {
    if (this.resultsTarget.hasAttribute("data-search-ahead-shown")) { this.clear() }
  }

  disconnect() {
    window.clearTimeout(this.timer)
  }

  queue() {
    window.clearTimeout(this.timer)
    this.timer = window.setTimeout(() => this.search(), this.delayValue)
  }

  search() {
    const url = new URL(this.urlValue, window.location.href)
    url.searchParams.set(this.paramValue, this.fieldTarget.value)
    Object.entries(this.paramsValue).forEach(([key, value]) => url.searchParams.set(key, value))
    this.resultsTarget.setAttribute("data-search-ahead-shown", "")
    this.resultsTarget.src = url.toString()
  }

  loaded() {
    if (!this.newTabValue) { return }
    this.resultsTarget.querySelectorAll(".request_short_listing a").forEach((link) => {
      link.target = "_blank"
      link.rel = "noopener"
    })
  }

  // Clear frame when search redirects (e.g. private archive) with no matching frame.
  missing(event) {
    event.preventDefault()
    this.clear()
  }

  close(event) {
    event.preventDefault()
    this.clear()
  }

  // Removing src also cancels a search still on its way.
  clear() {
    this.resultsTarget.removeAttribute("src")
    this.resultsTarget.removeAttribute("data-search-ahead-shown")
    this.resultsTarget.replaceChildren()
  }
}
