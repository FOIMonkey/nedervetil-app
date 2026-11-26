import { Controller } from "@hotwired/stimulus"

// Rendered only after complete authentication. The server has already
// consumed the one-use return and claimed any owned draft; this never sends.
export default class extends Controller {
  static values = { return: String }

  connect() {
    this.tell("signin:success")
  }

  continue(event) {
    if (window.parent === window) { return }
    event.preventDefault()
    this.tell("signin:close")
  }

  tell(type) {
    if (window.parent === window) { return }
    window.parent.postMessage({ type, path: this.returnValue }, window.location.origin)
  }
}
