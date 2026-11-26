import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    const loading = this.loading = Promise.all([
      import("editor/box_editor"),
      import("editor/unsaved_work")
    ]).then(([{ Editor }, { UnsavedWork }]) => {
      // Disconnected, or connected again, while the modules loaded.
      if (this.loading !== loading) { return }
      this.editor = new Editor(this.element)
      this.unsaved = new UnsavedWork(this.element, this.editor, null)
    })
  }

  disconnect() {
    this.loading = null
    if (this.unsaved) { this.unsaved.destroy() }
    if (this.editor) { this.editor.destroy() }
    this.unsaved = this.editor = null
  }
}
