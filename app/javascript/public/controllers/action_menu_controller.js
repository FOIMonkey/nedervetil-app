import { Controller } from "@hotwired/stimulus"

// Dropdown menu controller using legacy dropit* CSS classes expected by core/theme stylesheets.
export default class extends Controller {
  static targets = ["button", "menu"]

  connect() {
    this.element.classList.add("dropit")
    this.item = this.buttonTarget.closest("li")
    this.item.classList.add("dropit-trigger")
    this.menuTarget.classList.add("dropit-submenu")
    this.buttonTarget.setAttribute("role", "button")
    this.buttonTarget.setAttribute("aria-haspopup", "true")
    // Reset state when restored from Turbo cache.
    this.close()
  }

  toggle(event) {
    event.preventDefault()
    this.isOpen() ? this.close() : this.open()
  }

  key(event) {
    if (event.key !== " ") { return }
    this.toggle(event)
  }

  outside(event) {
    if (this.isOpen() && !this.element.contains(event.target)) { this.close() }
  }

  escape(event) {
    if (event.key !== "Escape" || !this.isOpen()) { return }
    this.close()
    this.buttonTarget.focus()
  }

  open() {
    this.item.classList.add("dropit-open")
    this.buttonTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.item.classList.remove("dropit-open")
    this.buttonTarget.setAttribute("aria-expanded", "false")
  }

  isOpen() {
    return this.item.classList.contains("dropit-open")
  }
}
