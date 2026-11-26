import { Controller } from "@hotwired/stimulus"

// Auto-submits the form via requestSubmit() so submit listeners (confirm, form-lock) still run.
export default class extends Controller {
  submit() {
    const form = this.element.closest("form") || this.element
    if (form.requestSubmit) { form.requestSubmit() } else { form.submit() }
  }
}
