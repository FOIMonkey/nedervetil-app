import { Controller } from "@hotwired/stimulus"

// Loads holiday new/edit forms inline; falls back to full navigation on error or without JS.
export default class extends Controller {
  static targets = ["existing", "row"]

  new(event) {
    event.preventDefault()
    this.load(event.currentTarget.href).then((html) => {
      this.existingTarget.insertAdjacentHTML("beforebegin", html)
    })
  }

  edit(event) {
    event.preventDefault()
    const row = event.currentTarget.closest("[data-holidays-target~='row']")
    this.load(event.currentTarget.href).then((html) => { row.innerHTML = html })
  }

  load(url) {
    return fetch(url, {
      credentials: "same-origin",
      headers: { "X-Requested-With": "XMLHttpRequest", Accept: "text/html" }
    }).then((response) => {
      if (!response.ok) { throw new Error(response.statusText) }
      return response.text()
    }).catch(() => { window.location.href = url; return new Promise(() => {}) })
  }
}
