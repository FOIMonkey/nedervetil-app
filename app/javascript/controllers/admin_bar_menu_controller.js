import { Controller } from "@hotwired/stimulus"

// Enhances the native <details class="admin-bar__more"> Tools menu: keeps it
// closed on Turbo Back snapshots, and closes it on Escape or clicking outside.
// Works with JavaScript disabled as a plain <details> disclosure.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.close()
  }

  escape(event) {
    if (event.key !== "Escape" || !this.element.open) { return }
    this.close()
    if (this.hasToggleTarget) { this.toggleTarget.focus() }
  }

  outside(event) {
    if (this.element.open && !this.element.contains(event.target)) {
      this.close()
    }
  }

  close() {
    this.element.open = false
  }
}
