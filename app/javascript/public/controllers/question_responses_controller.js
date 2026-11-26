import { Controller } from "@hotwired/stimulus"

// Highlights the response matching the selected authority pre-request question.
export default class extends Controller {
  static targets = ["response"]

  connect() {
    // A reload can keep the checked answer.
    const checked = this.element.querySelector('input[name="request_form_response"]:checked')
    if (checked) { this.show(checked.value) }
  }

  pick(event) {
    if (event.target.name === "request_form_response") { this.show(event.target.value) }
  }

  show(key) {
    this.responseTargets.forEach((response) => {
      response.classList.toggle("request_form_response--focused", response.id === `request_form_response--${key}`)
    })
  }
}
