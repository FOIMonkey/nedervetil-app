import { Controller } from "@hotwired/stimulus"

// Jumping to something on the page takes keyboard users there too.
export default class extends Controller {
  focus(event) {
    const link = event.target.closest('a[href^="#"]')
    const target = link && document.getElementById(link.getAttribute("href").slice(1))
    if (!target) { return }
    target.setAttribute("tabindex", "-1")
    target.focus({ preventScroll: true })
  }
}
