import { Controller } from "@hotwired/stimulus"

// Escape shuts an open <details> and puts focus back on its summary.
export default class extends Controller {
  // keydown@document
  close(event) {
    if (event.key !== "Escape" || !this.element.open) { return }
    this.element.open = false
    const summary = this.element.querySelector("summary")
    if (summary) { summary.focus() }
  }
}
