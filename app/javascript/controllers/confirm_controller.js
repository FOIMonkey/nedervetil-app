import { Controller } from "@hotwired/stimulus"

// Handles data-confirm on body; must precede method-link and form-lock so cancellation stops them.
export default class extends Controller {
  click(event) {
    const element = event.target.closest("a[data-confirm], button[data-confirm], input[type=submit][data-confirm], input[type=image][data-confirm]")
    if (!element || !this.element.contains(element)) { return }
    this.ask(event, element.getAttribute("data-confirm"))
  }

  submit(event) {
    const form = event.target
    if (!form.matches || !form.matches("form[data-confirm]")) { return }
    // The submitting button already asked when it was clicked.
    if (event.submitter && event.submitter.hasAttribute("data-confirm")) { return }
    this.ask(event, form.getAttribute("data-confirm"))
  }

  ask(event, message) {
    if (!message || window.confirm(message)) { return }
    event.preventDefault()
    event.stopImmediatePropagation()
  }
}
