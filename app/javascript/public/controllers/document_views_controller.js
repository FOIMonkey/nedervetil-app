import { Controller } from "@hotwired/stimulus"

// Toggles document Pages/Text views without reloading; links fall back to ?view=.
export default class extends Controller {
  swap(event) {
    const link = event.target.closest("[data-document-view]")
    if (!link || event.metaKey || event.ctrlKey || event.shiftKey) { return }
    const target = link.hash ? document.getElementById(link.hash.slice(1)) : null
    event.preventDefault()
    this.show(link.getAttribute("data-document-view"))
    if (target) { target.scrollIntoView() }
  }

  show(view) {
    const pagesView = document.getElementById("document-pages-view")
    const textView = document.getElementById("document-text-view")
    if (!pagesView || !textView) { return }
    pagesView.hidden = view === "text"
    textView.hidden = view !== "text"
    const thumbs = document.querySelector(".document-thumbs")
    if (thumbs) { thumbs.hidden = view === "text" }
    document.querySelectorAll(".document-views__link").forEach((link) => {
      if (link.getAttribute("data-document-view") === view) {
        link.setAttribute("aria-current", "true")
      } else {
        link.removeAttribute("aria-current")
      }
    })
    const url = new URL(window.location.href)
    url.searchParams.set("view", view)
    url.hash = ""
    // Preserve window.history.state so Turbo Drive Back/Forward restoration works.
    window.history.replaceState(window.history.state, "", url)
  }
}
