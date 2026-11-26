import { Controller } from "@hotwired/stimulus"

// Theme modal (responsive/modal.scss) with focus trap; clickOutsideClose=false also disables Escape.
const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"]):not(.focus-trap-start):not(.focus-trap-end), iframe[src*="youtube"]'

export default class extends Controller {
  static targets = ["content"]
  static values = {
    autoOpen: Boolean,
    openDelay: { type: Number, default: 0 },
    clickOutsideClose: { type: Boolean, default: true }
  }

  connect() {
    this.escape = this.escape.bind(this)
    this.backdrop = this.backdrop.bind(this)
    document.addEventListener("keydown", this.escape)
    this.contentTarget.addEventListener("click", this.backdrop)
    // Ensure closed on Turbo cache restore (overlay and focus traps are data-uncached).
    if (this.isOpen()) {
      this.contentTarget.classList.add("modal-hidden")
      this.contentTarget.setAttribute("aria-hidden", "true")
      document.body.style.overflow = ""
    }
    if (this.autoOpenValue) {
      this.timer = window.setTimeout(() => this.open(), this.openDelayValue)
    }
  }

  disconnect() {
    document.removeEventListener("keydown", this.escape)
    this.contentTarget.removeEventListener("click", this.backdrop)
    window.clearTimeout(this.timer)
    if (this.isOpen()) { this.close() }
  }

  open(event) {
    if (event) { event.preventDefault() }
    if (this.isOpen()) { return }
    this.lastFocused = document.activeElement
    this.contentTarget.classList.remove("modal-hidden")
    this.contentTarget.setAttribute("aria-hidden", "false")

    this.overlay = document.createElement("div")
    this.overlay.className = "modal-overlay"
    this.overlay.setAttribute("data-uncached", "")
    this.overlay.addEventListener("click", () => this.outside())
    document.body.appendChild(this.overlay)
    document.body.style.overflow = "hidden"

    this.trap()
    const first = this.focusable()[0]
    if (first) { window.setTimeout(() => first.focus(), 100) }
  }

  close(event) {
    if (event) { event.preventDefault() }
    if (!this.isOpen()) { return }
    this.contentTarget.querySelectorAll('iframe[src*="youtube"]').forEach((frame) => {
      frame.contentWindow.postMessage('{"event":"command","func":"stopVideo","args":""}', "*")
    })
    this.contentTarget.querySelectorAll(".focus-trap-start, .focus-trap-end").forEach((trap) => trap.remove())
    this.contentTarget.classList.add("modal-hidden")
    this.contentTarget.setAttribute("aria-hidden", "true")
    if (this.overlay) { this.overlay.remove() }
    this.overlay = null
    document.body.style.overflow = ""
    if (this.lastFocused) { window.setTimeout(() => this.lastFocused.focus(), 10) }
  }

  backdrop(event) {
    if (event.target === this.contentTarget) { this.outside() }
  }

  escape(event) {
    if (event.key === "Escape" && this.isOpen()) { this.outside() }
  }

  outside() {
    if (this.clickOutsideCloseValue) { this.close() }
  }

  isOpen() {
    return this.contentTarget.getAttribute("aria-hidden") === "false"
  }

  focusable() {
    return Array.from(this.contentTarget.querySelectorAll(FOCUSABLE)).
      filter((element) => element.offsetWidth > 0 && element.offsetHeight > 0)
  }

  // Sentinels at either end send focus round to the other.
  trap() {
    const sentinel = (className, pick) => {
      const element = document.createElement("div")
      element.tabIndex = 0
      element.className = className
      element.setAttribute("data-uncached", "")
      element.style.cssText = "position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0;"
      element.addEventListener("focus", () => {
        const focusable = this.focusable()
        if (focusable.length) { pick(focusable).focus() }
      })
      return element
    }
    this.contentTarget.prepend(sentinel("focus-trap-start", (list) => list[list.length - 1]))
    this.contentTarget.append(sentinel("focus-trap-end", (list) => list[0]))
  }
}
