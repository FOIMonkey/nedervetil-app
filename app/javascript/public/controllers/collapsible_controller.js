import { Controller } from "@hotwired/stimulus"

// Collapsible thread message; routine updates start collapsed unless targeted by the URL hash.
export default class extends Controller {
  static targets = ["trigger", "header"]
  static values = { routine: Boolean }

  connect() {
    if (this.routineValue && !this.linkedInto()) { this.element.classList.add("collapsed") }
    this.triggerTargets.forEach((trigger) => {
      trigger.setAttribute("role", "button")
      trigger.setAttribute("tabindex", "0")
      if (this.element.id) { trigger.setAttribute("aria-controls", this.element.id) }
    })
    this.sync()
  }

  toggle() {
    this.element.classList.toggle("collapsed")
    this.sync()
  }

  key(event) {
    if (event.key !== "Enter" && event.key !== " ") { return }
    event.preventDefault()
    this.toggle()
  }

  headerClick(event) {
    if (event.target === event.currentTarget) { this.toggle() }
  }

  hover(event) {
    if (event.target !== event.currentTarget || !this.hasHeaderTarget) { return }
    this.headerTarget.classList.toggle("hovered", event.type === "mouseover")
  }

  set(event) {
    this.element.classList.toggle("collapsed", !event.detail.expanded)
    this.sync()
  }

  reveal() {
    if (this.linkedInto()) {
      this.element.classList.remove("collapsed")
      this.sync()
    }
  }

  linkedInto() {
    let id
    try { id = decodeURIComponent(window.location.hash.slice(1)) } catch (_) { return false }
    if (!id) { return false }
    const target = document.getElementById(id)
    return !!target && this.element.contains(target)
  }

  sync() {
    const expanded = String(!this.element.classList.contains("collapsed"))
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", expanded))
  }
}
