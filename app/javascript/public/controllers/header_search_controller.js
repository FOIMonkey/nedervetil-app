import { Controller } from "@hotwired/stimulus"

// On narrow screens, first tap expands and focuses the collapsed header search instead of submitting.
export default class extends Controller {
  static targets = ["field", "button"]

  folded() {
    return this.narrow() && !this.element.contains(document.activeElement)
  }

  narrow() {
    return window.matchMedia("(max-width: 35em)").matches
  }

  // Prevent focus change from shifting the button away before click/submit.
  hold(event) {
    if (this.folded()) { event.preventDefault() }
  }

  open(event) {
    if (this.folded() || (this.narrow() && !this.fieldTarget.value.trim())) {
      event.preventDefault()
      this.fieldTarget.focus()
    }
  }
}
