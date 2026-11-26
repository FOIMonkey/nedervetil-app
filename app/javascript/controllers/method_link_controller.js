import { Controller } from "@hotwired/stimulus"
import { csrfParam, csrfToken } from "helpers/csrf"

// Submits a hidden POST form for legacy data-method links; prefer button_to in new views.
export default class extends Controller {
  follow(event) {
    const link = event.target.closest("a[data-method]")
    if (!link || !this.element.contains(link) || event.defaultPrevented) { return }
    const method = (link.getAttribute("data-method") || "get").toLowerCase()
    if (method === "get") { return }
    event.preventDefault()

    const form = document.createElement("form")
    form.method = "post"
    form.action = link.href
    form.hidden = true
    if (link.target) { form.target = link.target }
    this.field(form, "_method", method)
    if (this.sameOrigin(link)) { this.field(form, csrfParam(), csrfToken()) }
    document.body.appendChild(form)
    form.submit()
  }

  field(form, name, value) {
    if (!name || value === null) { return }
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    form.appendChild(input)
  }

  sameOrigin(link) {
    return link.origin === window.location.origin
  }
}
