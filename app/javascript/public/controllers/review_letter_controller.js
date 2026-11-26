import { Controller } from "@hotwired/stimulus"

// Live-updates the Scottish review letter preview from the selected reason and extra text.
export default class extends Controller {
  static targets = ["sentence", "more", "input"]

  reason(event) {
    if (event.target.name !== "review_reason") { return }
    this.sentenceTarget.textContent = event.target.getAttribute("data-sentence")
    this.sentenceTarget.classList.remove("followup-letter__gap")
  }

  copy() {
    if (this.hasMoreTarget) { this.moreTarget.textContent = this.inputTarget.value }
  }
}
