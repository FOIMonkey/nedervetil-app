import { Controller } from "@hotwired/stimulus"

// "Collapse all correspondence" / "Expand all correspondence": folds or
// opens every message and swaps its own words.
export default class extends Controller {
  static values = { expanded: String, collapsed: String }

  toggle(event) {
    event.preventDefault()
    const expand = this.element.textContent.trim() === this.collapsedValue
    window.dispatchEvent(new CustomEvent("collapsible:set", { detail: { expanded: expand } }))
    this.element.textContent = expand ? this.expandedValue : this.collapsedValue
  }

  // It's a link, so Enter already clicks it; Space does too, as on a button.
  key(event) {
    if (event.key !== " ") { return }
    this.toggle(event)
  }
}
