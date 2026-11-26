import { Controller } from "@hotwired/stimulus"

// Switches locale tab panels in Admin::TranslatedRecordForm without Bootstrap's
// data-toggle="tab". All locale panels remain visible if JavaScript is off.
export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    const initial = this.tabTargets.find((tab) => tab.getAttribute("aria-selected") === "true") ||
      this.tabTargets[0]
    if (initial) { this.activate(initial) }
  }

  select(event) {
    event.preventDefault()
    this.activate(event.currentTarget)
  }

  activate(activeTab) {
    const targetId = activeTab.getAttribute("aria-controls")
    this.tabTargets.forEach((tab) => {
      const selected = tab === activeTab
      tab.setAttribute("aria-selected", selected ? "true" : "false")
      if (tab.parentElement) {
        tab.parentElement.classList.toggle("active", selected)
      }
    })
    this.panelTargets.forEach((panel) => {
      const show = panel.id === targetId
      panel.hidden = !show
      panel.classList.toggle("active", show)
    })
  }
}
