import { Controller } from "@hotwired/stimulus"
import { showBriefly } from "helpers/show_briefly"

// Copies a data-clipboard-text-value string (for text not rendered on the page).
export default class extends Controller {
  static values = { text: String, success: String }

  async copy(event) {
    event.preventDefault()
    if (!navigator.clipboard) { return }
    try {
      await navigator.clipboard.writeText(this.textValue)
    } catch (_) {
      return
    }
    this.confirm()
  }

  confirm() {
    if (this.successValue) { showBriefly(this.element, this.successValue) }
  }
}
