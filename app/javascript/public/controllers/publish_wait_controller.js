import { Controller } from "@hotwired/stimulus"
import { LANDED_KEY, land } from "controllers/publish_landing_controller"
import { driveOn, visitInProgress } from "helpers/turbo_cache"

// Poll file readiness with backoff, then morph-refresh #content and focus the destination heading.
const DELAYS = [300, 500, 750, 1000]
const THEN = 2000
const LIMIT = 300000
const FAILURES = 5
const HANG = 15000

// Preserve the five-minute limit across self-refreshes; other visits reset it.
// Turbo.visit fires turbo:visit synchronously while refreshing is true.
const startedAt = new Map()
let refreshing = false
document.addEventListener("turbo:visit", () => {
  if (!refreshing) { startedAt.clear() }
})

export default class extends Controller {
  connect() {
    const path = window.location.pathname
    if (!startedAt.has(path)) { startedAt.set(path, Date.now()) }
    this.started = startedAt.get(path)
    this.tries = 0
    this.failures = 0
    this.stopped = false
    this.waitingText = this.element.querySelector("[data-publish-status]").textContent
    if (!window.fetch) { return }
    this.showBar(true)
    this.next()
  }

  // Prevent late responses from reviving polling or navigating away.
  disconnect() {
    this.stopped = true
    window.clearTimeout(this.timer)
    if (this.asking) { this.asking.abort() }
    this.asking = null
    window.clearTimeout(this.hung)
  }

  next() {
    if (this.stopped) { return }
    if (Date.now() - this.started > LIMIT) { this.giveUp(); return }
    const delay = this.tries < DELAYS.length ? DELAYS[this.tries] : THEN
    this.tries += 1
    this.timer = window.setTimeout(() => this.ask(), delay)
  }

  ask() {
    const wait = this.element
    // One that never comes back counts as a failure, or asking would stop.
    const asking = this.asking = new AbortController()
    const hung = this.hung = window.setTimeout(() => asking.abort(), HANG)
    fetch(wait.getAttribute("data-publish-wait"), { credentials: "same-origin", signal: asking.signal, headers: { Accept: "application/json" } })
      .then((response) => {
        window.clearTimeout(hung)
        // Signed out, or no longer theirs to see: asking again can't help.
        if ([401, 403, 404].indexOf(response.status) > -1) { return null }
        if (!response.ok) { throw new Error("status " + response.status) }
        return response.json()
      })
      .then((status) => {
        if (this.stopped || this.asking !== asking) { return }
        if (!status) { this.failures += 1; this.giveUp(); return }
        if (this.failures >= FAILURES) { this.askingAgain() }
        this.failures = 0
        this.showReady(status.documents || {})
        const only = wait.getAttribute("data-publish-only")
        const done = only ? status.documents && status.documents[only] : status.ready
        if (!done && !status.stuck) { this.next(); return }
        wait.querySelector("[data-publish-status]").textContent = wait.getAttribute("data-publish-all-ready")
        this.showBar(false)
        this.moveOn()
      })
      .catch(() => {
        window.clearTimeout(hung)
        if (this.stopped || this.asking !== asking) { return }
        this.failures += 1
        if (this.failures === FAILURES) { this.offerAgain(wait.getAttribute("data-publish-cant-check")) }
        this.next()
      })
  }

  showReady(documents) {
    this.element.querySelectorAll("[data-publish-file]").forEach((file) => {
      if (!documents[file.getAttribute("data-publish-file")]) { return }
      file.querySelector("[data-publish-word]").textContent = this.element.getAttribute("data-publish-word-ready")
    })
  }

  showBar(shown) {
    const bar = this.element.querySelector("[data-publish-bar]")
    if (bar) { bar.hidden = !shown }
  }

  offerAgain(message) {
    this.showBar(false)
    this.element.querySelector("[data-publish-status]").textContent = message
    this.element.querySelector("[data-publish-again]").hidden = false
  }

  askingAgain() {
    this.showBar(true)
    this.element.querySelector("[data-publish-status]").textContent = this.waitingText
    this.element.querySelector("[data-publish-again]").hidden = true
  }

  giveUp() {
    this.offerAgain(this.element.getAttribute(this.failures ? "data-publish-cant-check" : "data-publish-slow"))
  }

  moveOn() {
    if (this.element.hasAttribute("data-publish-saved")) { this.reloadSaved(); return }
    if (!driveOn()) { this.reload(); return }
    // Don't interrupt an in-progress navigation or form submission.
    const visit = visitInProgress()
    const leaving = visit && !visit.isSamePage && visit.state === "started"
    const submission = window.Turbo.navigator.formSubmission
    const submitting = submission && submission.state !== "stopped"
    if (leaving || submitting) { return }

    const path = window.location.pathname
    // Fall back to a full reload if the morph refresh hangs.
    const fallback = window.setTimeout(() => {
      if (window.location.pathname === path) { this.reload() }
    }, HANG)
    const content = document.getElementById("content")
    document.addEventListener("turbo:load", () => {
      window.clearTimeout(fallback)
      forgetLanding()
      if (window.location.pathname !== path) { return }
      if (document.querySelector("[data-publish-wait]")) { return }
      if (typingOutside(content)) { return }
      land()
    }, { once: true })
    // Persist landing intent in case Turbo falls back to a full page load.
    rememberLanding()
    refreshing = true
    try {
      window.Turbo.visit(window.location.href, {
        action: "replace",
        refresh: { method: "morph", scroll: "preserve" }
      })
    } finally {
      refreshing = false
    }
  }

  reload() {
    rememberLanding()
    window.location.reload()
  }

  // Back from saving: the page says that it worked (PublishingController#redact).
  reloadSaved() {
    const url = new URL(window.location.href)
    url.searchParams.set("saved", "1")
    window.location.replace(url)
  }
}

function rememberLanding() {
  try { window.sessionStorage.setItem(LANDED_KEY, "1") } catch (_) { /* land from the top instead */ }
}

function forgetLanding() {
  try { window.sessionStorage.removeItem(LANDED_KEY) } catch (_) { /* nothing was kept */ }
}

function typingOutside(content) {
  const active = document.activeElement
  if (!active || !active.matches("input, textarea, select, [contenteditable]")) { return false }
  return !(content && content.contains(active))
}
