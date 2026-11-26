import { Controller } from "@hotwired/stimulus"

// Ticked messages on the admin request page go to the bulk destroy form as
// a comma-separated list of ids; its button works once one is ticked.
export default class extends Controller {
  static targets = ["checkbox", "ids", "submit"]

  connect() { this.update() }

  update() {
    const ids = this.checkboxTargets.filter((box) => box.checked).map((box) => box.value)
    if (this.hasIdsTarget) { this.idsTarget.value = ids.join(",") }
    if (this.hasSubmitTarget) { this.submitTarget.disabled = ids.length === 0 }
  }
}
