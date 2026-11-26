import { Controller } from "@hotwired/stimulus"

// Loads triage detail links into their <turbo-frame> while keeping Turbo Drive off /admin.
export default class extends Controller {
  static targets = ["item"]

  select(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey ||
        (event.button !== undefined && event.button !== 0)) {
      return
    }
    this.loadLink(event.currentTarget, event)
  }

  selectRow(event) {
    if (event.target.closest("a, button, input, select, textarea, summary, label")) {
      return
    }
    const link = event.currentTarget.querySelector("a[data-triage-list-target='item']")
    if (!link) { return }
    this.loadLink(link, event)
  }

  keydown(event) {
    const tag = event.target && event.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" ||
        (event.target && event.target.isContentEditable)) {
      return
    }
    if (event.metaKey || event.ctrlKey || event.altKey) { return }
    if (event.key !== "j" && event.key !== "k") { return }

    const visible = this.itemTargets.filter((el) => el.offsetParent !== null)
    if (!visible.length) { return }

    event.preventDefault()
    const currentIndex = visible.findIndex((el) => el.getAttribute("aria-current") === "true")
    let nextIndex
    if (event.key === "j") {
      nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % visible.length
    } else {
      nextIndex = currentIndex <= 0 ? visible.length - 1 : currentIndex - 1
    }

    const next = visible[nextIndex]
    next.scrollIntoView({ block: "nearest" })
    this.loadLink(next)
  }

  loadLink(link, event = null) {
    const targetUrl = new URL(link.href, window.location.href)
    if (targetUrl.origin !== window.location.origin) { return }
    const frameId = link.dataset.turboFrame
    const frame = frameId ? document.getElementById(frameId) : null
    this.markActive(link)
    if (frame) {
      if (event) { event.preventDefault() }
      frame.src = targetUrl.toString()
    }
  }

  markActive(active) {
    this.itemTargets.forEach((item) => {
      const selected = item === active
      const row = item.closest("li, article.admin-request-row, details.admin-row-details")
      if (selected) {
        item.setAttribute("aria-current", "true")
        if (row) { row.dataset.selected = "true" }
      } else {
        item.removeAttribute("aria-current")
        if (row) { delete row.dataset.selected }
      }
    })
  }
}
