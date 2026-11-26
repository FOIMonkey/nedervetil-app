import { Controller } from "@hotwired/stimulus"

// Admin jump command palette; loads server-rendered results into a <turbo-frame>.
export default class extends Controller {
  static targets = ["dialog", "input", "frame"]
  static values = { url: String }

  connect() {
    this.activeIndex = 0
    this.lastQuery = null
  }

  disconnect() {
    window.clearTimeout(this.timer)
  }

  shortcut(event) {
    const tag = event.target && event.target.tagName
    const inField = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" ||
      (event.target && event.target.isContentEditable)

    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault()
      this.openDialog()
      return
    }
    if (!inField && event.key === "/" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault()
      this.openDialog()
    }
  }

  open(event) {
    if (!this.hasDialogTarget) { return }
    event.preventDefault()
    this.openDialog()
  }

  openDialog() {
    if (!this.hasDialogTarget) { return }
    if (!this.dialogTarget.open) {
      this.dialogTarget.showModal()
    }
    if (this.hasInputTarget) {
      this.inputTarget.focus()
      this.inputTarget.select()
      const q = this.inputTarget.value.trim()
      if (q.length >= 2 || /^#\d+$/.test(q)) {
        this.fetchResults(q)
      }
    }
  }

  close() {
    if (this.hasDialogTarget && this.dialogTarget.open) {
      this.dialogTarget.close()
    }
  }

  backdropClick(event) {
    if (event.target === this.dialogTarget) {
      this.close()
    }
  }

  queue() {
    window.clearTimeout(this.timer)
    this.timer = window.setTimeout(() => {
      const q = this.inputTarget.value.trim()
      if (q.length === 1 && !/^#\d/.test(q)) { return }
      this.fetchResults(q)
    }, 250)
  }

  fetchResults(query) {
    if (!this.hasFrameTarget) { return }
    if (query === this.lastQuery) { return }
    this.lastQuery = query
    const url = new URL(this.urlValue, window.location.href)
    url.searchParams.set("q", query)
    url.searchParams.set("frame", this.frameTarget.id)
    this.frameTarget.src = url.toString()
  }

  frameLoaded() {
    this.activeIndex = 0
    this.highlightActive()
  }

  navigate(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      return
    }

    const items = this.resultLinks()
    if (!items.length) { return }

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.activeIndex = (this.activeIndex + 1) % items.length
      this.highlightActive()
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.activeIndex = (this.activeIndex - 1 + items.length) % items.length
      this.highlightActive()
    } else if (event.key === "Enter" && items[this.activeIndex]) {
      event.preventDefault()
      items[this.activeIndex].click()
    }
  }

  resultLinks() {
    if (!this.hasFrameTarget) { return [] }
    return Array.from(this.frameTarget.querySelectorAll("a.admin-jump__item"))
  }

  highlightActive() {
    this.resultLinks().forEach((link, idx) => {
      const active = idx === this.activeIndex
      link.setAttribute("aria-selected", active ? "true" : "false")
      if (active) { link.scrollIntoView({ block: "nearest" }) }
    })
  }
}
