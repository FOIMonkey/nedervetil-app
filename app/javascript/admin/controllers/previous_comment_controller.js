import { Controller } from "@hotwired/stimulus"

// Puts the last edit comment back in its field. Hidden until scripts run.
export default class extends Controller {
  static values = { field: String, text: String }

  connect() { this.element.hidden = false }

  use(event) {
    event.preventDefault()
    const field = document.getElementById(this.fieldValue)
    if (field) { field.value = this.textValue }
  }
}
