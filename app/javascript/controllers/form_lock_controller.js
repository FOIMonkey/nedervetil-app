import { Controller } from "@hotwired/stimulus"

// Disables data-disable-with buttons on submit and restores them on bfcache/Turbo cache return.
export default class extends Controller {
  connect() {
    this.restore = this.restore.bind(this)
    window.addEventListener("pageshow", this.restore)
    this.unlock()
  }

  disconnect() {
    window.removeEventListener("pageshow", this.restore)
  }

  lock(event) {
    const form = event.target
    if (event.defaultPrevented || !form.elements) { return }
    // Defer so the clicked button's name/value are submitted and later submit
    // listeners can still preventDefault() without leaving buttons locked.
    window.setTimeout(() => { if (!event.defaultPrevented) { this.disable(form) } }, 13)
  }

  disable(form) {
    Array.from(form.elements).forEach((field) => {
      const words = field.getAttribute("data-disable-with")
      if (!words || field.disabled) { return }
      field.setAttribute("data-form-lock-was", field.matches("button") ? field.innerHTML : field.value)
      if (field.matches("button")) { field.textContent = words } else { field.value = words }
      field.disabled = true
    })
  }

  restore(event) {
    if (event.persisted) { this.unlock() }
  }

  unlock() {
    this.element.querySelectorAll("[data-form-lock-was]").forEach((field) => {
      const was = field.getAttribute("data-form-lock-was")
      if (field.matches("button")) { field.innerHTML = was } else { field.value = was }
      field.removeAttribute("data-form-lock-was")
      field.disabled = false
    })
  }
}
