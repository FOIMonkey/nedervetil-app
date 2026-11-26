import { Controller } from "@hotwired/stimulus"

// Explains a marked word in place on a help answer. Each word is a link to
// its entry on the words page, which is where it goes without JavaScript.
export default class extends Controller {
  connect() {
    // Back can show Turbo's copy of an answer left with a word explained.
    this.element.querySelectorAll(".help-word-means").
      forEach((means) => means.remove())
    this.element.querySelectorAll(".help-word").forEach((word) => {
      word.setAttribute("role", "button")
      word.setAttribute("aria-expanded", "false")
    })
  }

  toggle(event) {
    const word = event.target.closest(".help-word")
    if (!word) { return }

    event.preventDefault()
    const open = word.getAttribute("aria-expanded") === "true"
    word.setAttribute("aria-expanded", String(!open))
    const next = word.nextElementSibling
    if (open) {
      if (next && next.classList.contains("help-word-means")) { next.remove() }
    } else {
      const means = document.createElement("span")
      means.className = "help-word-means"
      means.textContent = word.dataset.means
      word.after(means)
    }
  }

  // A button answers to the space bar as well as Enter.
  press(event) {
    if (event.key !== " " || !event.target.closest(".help-word")) { return }

    event.preventDefault()
    event.target.click()
  }
}
