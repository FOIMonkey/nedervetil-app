import { Controller } from "@hotwired/stimulus"
import { showBriefly } from "helpers/show_briefly"

// A copy button stays hidden until the browser can copy; clicking it puts
// the text of the element named by data-copy on the clipboard.
export default class extends Controller {
  connect() {
    this.source = document.getElementById(this.element.getAttribute("data-copy"))
    if (!navigator.clipboard || !this.source) { return }
    this.done = this.element.getAttribute("data-copy-done") || "Copied"
    this.element.hidden = false
  }

  copy() {
    if (!navigator.clipboard || !this.source) { return }
    const text = this.source.value !== undefined ? this.source.value : this.source.textContent
    navigator.clipboard.writeText(text.replace(/\s+/g, " ").trim()).then(() => {
      showBriefly(this.element, this.done, 1500)
    })
  }
}
