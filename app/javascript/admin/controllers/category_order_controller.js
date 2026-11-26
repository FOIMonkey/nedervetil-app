import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import { backgroundHeaders } from "helpers/csrf"

// Create Sortable only while dragging: a live nested category list prevents
// its heading from moving more than one position.
export default class extends Controller {
  static targets = ["save", "notice"]
  static values = { list: String, url: String, handle: String }

  connect() {
    this.list = document.getElementById(this.listValue)
    if (!this.list) { return }
    this.press = this.press.bind(this)
    // Capture phase so Sortable exists before pointerdown reaches the list.
    this.list.addEventListener("pointerdown", this.press, true)
  }

  disconnect() {
    if (this.list) { this.list.removeEventListener("pointerdown", this.press, true) }
    this.release()
  }

  press(event) {
    if (this.sortable || event.button > 0) { return }
    const handle = this.handleValue && event.target.closest(this.handleValue)
    if (!handle || !Array.from(this.list.children).some((item) => item.contains(handle))) { return }

    // Scope draggable to direct children so nested category lists drag separately from headings.
    this.sortable = Sortable.create(this.list, {
      draggable: "> *",
      handle: this.handleValue,
      direction: "vertical",
      forceFallback: true,
      fallbackOnBody: true,
      fallbackTolerance: 4,
      invertSwap: true,
      animation: 150,
      ghostClass: "category-sort-placeholder",
      onUpdate: () => this.changed(),
      // Pointer-based dragging sweeps text selection unless suppressed while held.
      onChoose: () => {
        document.body.classList.add("category-sorting")
        const selection = window.getSelection()
        if (selection) { selection.removeAllRanges() }
      },
      // Destroy after Sortable finishes processing the drop.
      onUnchoose: () => {
        document.body.classList.remove("category-sorting")
        window.setTimeout(() => this.release(), 0)
      }
    })
  }

  release() {
    document.body.classList.remove("category-sorting")
    if (!this.sortable) { return }
    this.sortable.destroy()
    this.sortable = null
  }

  changed() {
    if (!this.disabled()) { return }
    this.saveTarget.classList.remove("disabled")
    this.saveTarget.removeAttribute("aria-disabled")
    this.say("unsaved-text")
    this.flash("save-panel--changed")
  }

  save(event) {
    event.preventDefault()
    if (this.disabled()) { return }

    const body = new URLSearchParams()
    Array.from(this.list.children).forEach((item) => {
      const match = /^categories_(.+)$/.exec(item.getAttribute("data-id") || "")
      if (match) { body.append("categories[]", match[1]) }
    })

    fetch(this.urlValue, {
      method: "POST",
      body,
      credentials: "same-origin",
      headers: backgroundHeaders()
    }).then((response) => {
      if (!response.ok) { return response.text().then((text) => { throw new Error(text) }) }
      this.saveTarget.classList.add("disabled")
      this.saveTarget.setAttribute("aria-disabled", "true")
      this.say("success-text")
      this.flash("save-panel--changed")
    }).catch((error) => {
      this.say("error-text", error.message)
      this.flash("save-panel--failed")
    })
  }

  disabled() {
    return this.saveTarget.classList.contains("disabled")
  }

  say(key, extra = "") {
    this.noticeTarget.textContent = (this.noticeTarget.getAttribute(`data-${key}`) || "") + extra
  }

  flash(className) {
    this.element.classList.remove("save-panel--changed", "save-panel--failed")
    // Restart the animation if it is already running.
    void this.element.offsetWidth
    this.element.classList.add(className)
  }
}
