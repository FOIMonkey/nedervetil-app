import { Controller } from "@hotwired/stimulus"

// A link or button that prints the page. Inline onclick handlers are
// blocked by the Content Security Policy, so it's bound here.
export default class extends Controller {
  print(event) {
    event.preventDefault()
    window.print()
  }
}
