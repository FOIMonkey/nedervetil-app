import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    const loading = this.loading = Promise.all([
      import("editor/text_redaction"),
      import("editor/unsaved_work")
    ]).then(([{ TextRedaction }, { UnsavedWork }]) => {
      // Disconnected, or connected again, while the modules loaded.
      if (this.loading !== loading) { return }
      this.editor = new TextRedaction(this.element)
      if (this.editor.field) {
        this.unsaved = new UnsavedWork(this.element, null, this.editor)
      }
    })
  }

  disconnect() {
    this.loading = null
    if (this.unsaved) { this.unsaved.destroy() }
    if (this.editor) { this.editor.destroy() }
    this.unsaved = this.editor = null
  }
}
