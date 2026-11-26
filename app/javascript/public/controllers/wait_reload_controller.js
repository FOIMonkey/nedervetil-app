import { Controller } from "@hotwired/stimulus"

// Polls an attachment wait page and reloads once the server returns a non-200 (e.g. redirect); <noscript> fallback.
const EVERY = 2000

export default class extends Controller {
  connect() {
    // Remember the wait URL so late replies don't reload after navigation.
    this.url = window.location.href
    this.schedule()
  }

  disconnect() {
    window.clearTimeout(this.timer)
    if (this.asking) { this.asking.abort() }
    this.asking = null
  }

  schedule() {
    this.timer = window.setTimeout(() => this.ask(), EVERY)
  }

  ask() {
    const asking = this.asking = new AbortController()
    fetch(this.url, {
      credentials: "same-origin",
      redirect: "manual",
      signal: asking.signal,
      headers: { Accept: "text/html" }
    })
      .then((response) => {
        // Abort can't cancel an already-queued callback, and the controller may have reconnected.
        if (this.asking !== asking) { return }
        if (response.status === 200) { this.schedule(); return }
        if (window.location.href === this.url) { window.location.reload() }
      })
      .catch((error) => {
        if (this.asking !== asking) { return }
        if (error.name !== "AbortError") { this.schedule() }
      })
  }
}
