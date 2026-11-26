import { Controller } from "@hotwired/stimulus"

// A note in the "original" style is plain text; every other style is rich
// text. Each locale shows the field its style uses. Without scripts both
// show.
export default class extends Controller {
  static targets = ["style", "body", "richBody"]

  connect() { this.update() }

  update() {
    const plain = this.styleTarget.value === "original"
    this.bodyTargets.forEach((field) => { field.hidden = !plain })
    this.richBodyTargets.forEach((field) => { field.hidden = plain })
  }
}
