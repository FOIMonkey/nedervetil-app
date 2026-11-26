import { Controller } from "@hotwired/stimulus"

// Enhances the header profile link into a menu button; initial visibility comes from CSS.
export default class extends Controller {
  static targets = ["link", "menu"]

  connect() {
    if (!this.hasLinkTarget || !this.hasMenuTarget) { return }
    this.linkTarget.setAttribute("role", "button")
    this.linkTarget.setAttribute("aria-haspopup", "true")
    // Clear inline display so CSS controls initial state (including on Turbo cache restore).
    this.menuTarget.style.removeProperty("display")
    this.linkTarget.setAttribute("aria-expanded", String(this.shown()))
  }

  toggle(event) {
    event.preventDefault()
    this.shown() ? this.close() : this.open()
  }

  key(event) {
    if (event.key !== " ") { return }
    event.preventDefault()
    this.toggle(event)
  }

  outside(event) {
    if (this.shown() && !this.element.contains(event.target)) { this.close() }
  }

  escape(event) {
    if (event.key !== "Escape" || !this.shown()) { return }
    this.close()
    this.linkTarget.focus()
  }

  open() {
    this.menuTarget.style.display = "block"
    this.linkTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.menuTarget.style.display = "none"
    this.linkTarget.setAttribute("aria-expanded", "false")
  }

  shown() {
    if (!this.hasMenuTarget) { return false }
    return window.getComputedStyle(this.menuTarget).display !== "none"
  }
}
