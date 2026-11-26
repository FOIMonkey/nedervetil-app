import { Controller } from "@hotwired/stimulus"

// The followup snippet library: the select shows only the snippets tagged
// with what it names ("all" for every one, or several space-separated
// tags for "my previous answers").
export default class extends Controller {
  static targets = ["select", "snippet"]

  connect() { this.filter() }

  filter() {
    const wanted = this.selectTarget.value.split(" ").filter(Boolean)
    this.snippetTargets.forEach((snippet) => {
      const tags = (snippet.getAttribute("data-tags") || "").split(" ").filter(Boolean)
      const shown = wanted.includes("all") || tags.some((tag) => wanted.includes(tag))
      if (shown) { snippet.removeAttribute("aria-hidden") } else { snippet.setAttribute("aria-hidden", "hidden") }
    })
  }
}
