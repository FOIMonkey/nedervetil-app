import { Controller } from "@hotwired/stimulus"
import { backgroundHeaders } from "helpers/csrf"

// Dismiss in the background so unsaved forms stay intact; falls back to button_to without JS.
export default class extends Controller {
  dismiss(event) {
    if (event.defaultPrevented) { return }
    const form = event.target
    event.preventDefault()
    fetch(form.action, {
      method: "POST",
      body: new FormData(form),
      credentials: "same-origin",
      headers: backgroundHeaders()
    }).catch(() => {})
    // Styles can give the announcement a display of its own.
    this.element.style.display = "none"
    this.dispatch("dismissed")
  }
}
