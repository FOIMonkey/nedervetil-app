import { Controller } from "@hotwired/stimulus"

// Inline delivery log toggle fetched from the status page; falls back to following the link.
export default class extends Controller {
  static targets = ["toggle", "text", "error"]

  // Sync link ARIA state on Turbo cache restore (the log box is data-uncached).
  connect() {
    if (this.toggleTarget.getAttribute("aria-expanded") !== "true") { return }
    this.toggleTarget.setAttribute("aria-expanded", "false")
    this.toggleTarget.removeAttribute("aria-controls")
    this.toggleTarget.classList.remove("toggle-delivery-log--loading")
  }

  // Morph refreshes reuse this instance after removing the box (helpers/morph_refresh), so clear this.box.
  disconnect() {
    if (this.box) { this.box.remove() }
    this.box = null
  }

  async toggle(event) {
    event.preventDefault()
    if (this.box) {
      this.hide()
      return
    }

    const box = document.createElement("div")
    box.className = `correspondence_delivery correspondence_delivery--${this.toggleTarget.dataset.deliveryStatus}`
    box.id = `${this.element.id}-delivery`
    box.setAttribute("role", "region")
    box.setAttribute("aria-live", "polite")
    box.setAttribute("data-uncached", "")
    this.textTarget.before(box)
    this.box = box
    this.toggleTarget.setAttribute("aria-controls", box.id)
    this.toggleTarget.setAttribute("aria-expanded", "true")
    this.toggleTarget.classList.add("toggle-delivery-log--loading")

    try {
      const response = await fetch(this.toggleTarget.href, { headers: { Accept: "text/html" } })
      if (!response.ok) { throw new Error(response.statusText) }
      const page = new DOMParser().parseFromString(await response.text(), "text/html")
      const log = page.querySelector(".controller_delivery_statuses")
      if (!log) { throw new Error("no log") }
      box.replaceChildren(...log.childNodes)
    } catch (_) {
      box.innerHTML = this.errorTarget.innerHTML
    } finally {
      this.toggleTarget.classList.remove("toggle-delivery-log--loading")
    }
  }

  hide() {
    if (!this.box) { return }
    this.box.remove()
    this.box = null
    this.toggleTarget.setAttribute("aria-expanded", "false")
  }
}
