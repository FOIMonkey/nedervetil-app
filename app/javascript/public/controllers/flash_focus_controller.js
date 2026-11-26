import { Controller } from "@hotwired/stimulus"

// Focuses flash notices on requester and publishing pages so notices take priority over hash fragments.
export default class extends Controller {
  connect() {
    if (!document.body.matches(".requester-view, .publish-view")) { return }
    // After the browser's own jump to the fragment, which clears focus.
    if (document.readyState === "complete") {
      window.setTimeout(() => this.show(), 0)
    } else {
      window.addEventListener("load", () => window.setTimeout(() => this.show(), 0), { once: true })
    }
  }

  show() {
    // Prepend error text to document.title so screen readers announce it first.
    if (this.element.querySelector("#error")) {
      document.title = `${this.element.textContent.trim().replace(/\s+/g, " ")} - ${document.title}`
    }
    this.element.setAttribute("tabindex", "-1")
    this.element.focus()
    this.element.scrollIntoView({ block: "center" })
  }
}
