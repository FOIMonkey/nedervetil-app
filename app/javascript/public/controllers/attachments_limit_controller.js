import { Controller } from "@hotwired/stimulus"

// A message with many attachments lists the first three, with a link to
// show the rest and to fold them away again. Without scripts all show.
export default class extends Controller {
  static targets = ["item", "toggle"]
  static values = { limit: { type: Number, default: 3 }, showAll: String, showFewer: String }

  connect() {
    this.extra = this.itemTargets.slice(this.limitValue)
    if (!this.extra.length || !this.hasToggleTarget) { return }
    this.collapse(true)
    this.toggleTarget.style.display = ""
    this.toggleTarget.setAttribute("role", "button")
  }

  toggle(event) {
    event.preventDefault()
    this.collapse(!this.collapsed)
  }

  collapse(collapsed) {
    this.collapsed = collapsed
    // Not hidden: the stylesheet gives an attachment a display of its own.
    this.extra.forEach((item) => { item.style.display = collapsed ? "none" : "" })
    this.toggleTarget.textContent = collapsed ? this.showAllValue : this.showFewerValue
    this.toggleTarget.setAttribute("aria-expanded", String(!collapsed))
  }
}
