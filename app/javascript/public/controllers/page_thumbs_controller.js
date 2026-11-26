import { Controller } from "@hotwired/stimulus"

// Marks the page being read in the thumbnail rail as the pages scroll by.
export default class extends Controller {
  connect() {
    if (!("IntersectionObserver" in window)) { return }
    const links = Array.from(this.element.querySelectorAll("[data-document-thumb]"))
    const pagesView = document.getElementById("document-pages-view")
    if (!pagesView) { return }
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) { return }
        links.forEach((link) => {
          if (link.getAttribute("data-document-thumb") === entry.target.id) {
            link.setAttribute("aria-current", "true")
          } else {
            link.removeAttribute("aria-current")
          }
        })
      })
    }, { rootMargin: "-40% 0px -55% 0px" })
    pagesView.querySelectorAll(".document-page").forEach((page) => this.observer.observe(page))
  }

  disconnect() {
    if (this.observer) { this.observer.disconnect() }
  }
}
