import { Controller } from "@hotwired/stimulus"

// Under a request's text, a word to the wise once it gets long. The
// thresholds and their messages come from the page; the message element
// carries the controller and names the text area it watches.
export default class extends Controller {
  static values = {
    field: String,
    thresholdL: Number, messageL: String,
    thresholdXl: Number, messageXl: String
  }

  connect() {
    this.field = document.querySelector(this.fieldValue)
    if (!this.field) { return }
    this.levels = [{ threshold: 0, css: "text-length-s", message: "" }]
    if (this.thresholdLValue && this.messageLValue) {
      this.levels.push({ threshold: this.thresholdLValue, css: "text-length-l", message: this.messageLValue })
    }
    if (this.thresholdXlValue && this.messageXlValue) {
      this.levels.push({ threshold: this.thresholdXlValue, css: "text-length-xl", message: this.messageXlValue })
    }
    this.levels.sort((a, b) => b.threshold - a.threshold)
    this.update = this.update.bind(this)
    this.field.addEventListener("input", this.update)
    this.field.addEventListener("change", this.update)
    this.update()
  }

  disconnect() {
    if (!this.field) { return }
    this.field.removeEventListener("input", this.update)
    this.field.removeEventListener("change", this.update)
  }

  update() {
    const length = this.field.value.length
    const level = this.levels.find((candidate) => length >= candidate.threshold)
    if (level === this.level) { return }
    this.level = level
    this.element.textContent = level.message
    this.levels.forEach((candidate) => this.element.classList.remove(candidate.css))
    this.element.classList.add(level.css)
  }
}
