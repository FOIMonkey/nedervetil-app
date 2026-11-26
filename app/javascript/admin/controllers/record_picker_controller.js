import { Controller } from "@hotwired/stimulus"

// Searchable record picker backed by a <turbo-frame>; degrades to a plain text input without JS.
export default class extends Controller {
  static targets = ["input", "frame", "preview", "previewName", "previewDetail", "submit"]
  static values = {
    url: String,
    scope: String,
    excludeId: Number
  }

  connect() {
    this.lastQuery = null
  }

  disconnect() {
    window.clearTimeout(this.timer)
  }

  queue() {
    window.clearTimeout(this.timer)
    this.hidePreview()
    this.timer = window.setTimeout(() => this.search(), 250)
  }

  search() {
    if (!this.hasFrameTarget) { return }
    const q = this.inputTarget.value.trim()
    if (q.length === 1) { return }
    if (q === this.lastQuery) { return }
    this.lastQuery = q
    const url = new URL(this.urlValue, window.location.href)
    url.searchParams.set("scope", this.scopeValue)
    url.searchParams.set("q", q)
    url.searchParams.set("frame", this.frameTarget.id)
    if (this.hasExcludeIdValue && this.excludeIdValue > 0) {
      url.searchParams.set("exclude_id", String(this.excludeIdValue))
    }
    this.frameTarget.src = url.toString()
  }

  pick(event) {
    const btn = event.currentTarget
    this.inputTarget.value = btn.dataset.recordValue || ""
    this.lastQuery = this.inputTarget.value.trim()
    if (this.hasPreviewNameTarget) {
      this.previewNameTarget.textContent = btn.dataset.recordName || ""
    }
    if (this.hasPreviewDetailTarget) {
      this.previewDetailTarget.textContent = btn.dataset.recordDetail || ""
    }
    if (this.hasPreviewTarget) {
      this.previewTarget.hidden = false
    }
    if (this.hasSubmitTarget) {
      this.submitTarget.focus()
    }
  }

  clear() {
    this.inputTarget.value = ""
    this.lastQuery = null
    this.hidePreview()
    this.inputTarget.focus()
  }

  hidePreview() {
    if (this.hasPreviewTarget) {
      this.previewTarget.hidden = true
    }
  }
}
