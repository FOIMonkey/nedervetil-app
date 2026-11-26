import { Controller } from "@hotwired/stimulus"

// Opens sign-in in a modal <dialog> for FORCE_REGISTRATION_ON_NEW_REQUEST and redirects on signin:success.
export default class extends Controller {
  static targets = ["frame"]
  static values = { src: String, next: String, trigger: String }

  connect() {
    this.openFromTrigger = this.openFromTrigger.bind(this)
    this.receive = this.receive.bind(this)
    document.addEventListener("click", this.openFromTrigger)
    window.addEventListener("message", this.receive)
    // Reset open state when restored from Turbo cache.
    this.element.removeAttribute("open")
  }

  disconnect() {
    document.removeEventListener("click", this.openFromTrigger)
    window.removeEventListener("message", this.receive)
  }

  openFromTrigger(event) {
    const trigger = event.target.closest(this.triggerValue)
    if (!trigger || event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.button > 0) { return }
    if (typeof this.element.showModal !== "function") { return }
    event.preventDefault()
    this.signedIn = false
    this.returnPath = null
    this.frameTarget.src = this.srcValue
    this.element.showModal()
  }

  close(event) {
    if (event) { event.preventDefault() }
    this.element.close()
  }

  closed() {
    this.frameTarget.src = "about:blank"
    if (this.signedIn) { window.location.href = this.returnPath || this.nextValue }
  }

  receive(event) {
    if (event.origin !== window.location.origin || event.source !== this.frameTarget.contentWindow) { return }
    const data = event.data || {}
    if (data.type === "signin:success") {
      if (typeof data.path !== "string" || !data.path.startsWith("/") || data.path.startsWith("//") || /[\\\x00-\x20]/.test(data.path)) { return }
      this.returnPath = data.path
      this.signedIn = true
    }
    if (data.type === "signin:close") { this.close() }
  }
}
