import { Controller } from "@hotwired/stimulus"
import { backgroundHeaders } from "helpers/csrf"

// Async Pro batch builder search/draft panes; syncs draft_id across forms, tabs, and URL.
export default class extends Controller {
  static targets = ["modeLink", "builder", "form", "query", "results", "draft", "count", "writeButton"]
  static values = { delay: { type: Number, default: 500 } }

  connect() {
    this.limit = parseInt(this.draftTarget.getAttribute("data-limit"), 10)
    this.searching = null
    this.updating = null
    this.loadingError = false
    this.resultsHtml = this.resultsTarget.innerHTML
    this.lastQuery = this.hasQueryTarget ? this.queryTarget.defaultValue : ""
    this.draftId = this.readDraftId()
    this.bodyIds = this.readBodyIds()
    this.reachedLimit = this.bodyIds.length >= this.limit

    this.collapseTopLevelGroups()
    this.refresh()
    // A field the browser filled back in no longer matches the results.
    if (this.hasQueryTarget && this.queryTarget.value !== this.lastQuery) { this.searchIfNeeded() }
  }

  disconnect() {
    window.clearTimeout(this.timer)
    if (this.searching) { this.searching.abort() }
    if (this.updating) { this.updating.abort() }
  }

  queueSearch() {
    window.clearTimeout(this.timer)
    this.timer = window.setTimeout(() => this.search(), this.delayValue)
  }

  search(event) {
    if (event) { event.preventDefault() }
    window.clearTimeout(this.timer)
    const query = this.queryTarget.value
    const params = { authority_query: query }
    if (this.draftId) { params.draft_id = this.draftId }
    this.load(this.formTarget.action, params).then((html) => {
      if (html === null) { return }
      this.lastQuery = query
    })
  }

  searchIfNeeded() {
    const visible = this.hasFormTarget && this.formTarget.offsetParent !== null
    if (visible && !this.reachedLimit && this.queryTarget.value !== this.lastQuery) {
      this.search()
    } else {
      this.renderResults()
    }
  }

  paginate(event) {
    const link = event.target.closest(".pagination a")
    if (!link) { return }
    event.preventDefault()
    if (link.classList.contains("disabled")) { return }
    const url = new URL(link.href, window.location.href)
    this.load(url.pathname, Object.fromEntries(url.searchParams))
  }

  load(path, params) {
    if (this.searching) { this.searching.abort() }
    const request = this.searching = new AbortController()
    const url = new URL(path, window.location.href)
    Object.entries(params).forEach(([name, value]) => url.searchParams.set(name, value))
    this.busy()
    return fetch(url, { credentials: "same-origin", headers: backgroundHeaders(), signal: request.signal }).
      then((response) => { if (!response.ok) { throw new Error(response.statusText) } return response.text() }).
      then((html) => {
        this.loadingError = false
        this.resultsHtml = html
        this.renderResults()
        return html
      }).
      catch((error) => {
        if (error.name === "AbortError") { return null }
        this.loadingError = true
        this.renderResults()
        return null
      }).
      finally(() => {
        if (this.searching === request) { this.searching = null }
        this.busy()
      })
  }

  renderResults() {
    let html = this.resultsHtml
    if (this.reachedLimit) {
      html = this.message("blank-slate", this.resultsTarget.getAttribute("data-limit-reached-message"))
    } else if (this.loadingError) {
      html = this.message("ajax-error", this.resultsTarget.getAttribute("data-ajax-error-message"))
    }
    if (this.resultsTarget.innerHTML !== html) {
      this.resultsTarget.innerHTML = html
      this.collapseTopLevelGroups()
    }
    this.refresh()
  }

  message(className, text) {
    const div = document.createElement("div")
    div.className = className
    div.textContent = text
    return div.outerHTML
  }

  collapseTopLevelGroups() {
    this.resultsTarget.querySelectorAll(".batch-builder__list > .batch-builder__list__group").forEach((group) => {
      if (group.dataset.batchBuilderCollapsed) { return }
      group.dataset.batchBuilderCollapsed = "true"
      this.setOpen(group, false)
    })
  }

  toggleGroup(event) {
    if (event.type === "keydown" && !["Enter", " "].includes(event.key)) { return }
    event.preventDefault()
    const item = event.currentTarget.closest(".batch-builder__list__item")
    const group = item && item.parentElement
    if (!group) { return }
    const list = Array.from(group.children).find((child) => child.matches("ul"))
    if (list) {
      this.setOpen(group, group.classList.contains("batch-builder__list__group--closed"))
    } else if (event.currentTarget.href) {
      this.fetchGroup(group, event.currentTarget.href)
    }
  }

  setOpen(group, open) {
    group.classList.toggle("batch-builder__list__group--closed", !open)
    const heading = group.querySelector(":scope > .batch-builder__list__item .batch-builder__list__item__anchor")
    if (heading) { heading.setAttribute("aria-expanded", String(open)) }
  }

  fetchGroup(group, href) {
    if (group.classList.contains("batch-builder__list__group--loading")) { return }
    group.classList.add("batch-builder__list__group--loading")
    fetch(this.withDraftId(href), { credentials: "same-origin", headers: backgroundHeaders() }).
      then((response) => { if (!response.ok) { throw new Error(response.statusText) } return response.text() }).
      then((html) => {
        group.insertAdjacentHTML("beforeend", html)
        this.setOpen(group, true)
        if (!this.reachedLimit && !this.loadingError) { this.resultsHtml = this.resultsTarget.innerHTML }
        this.refresh()
      }).
      catch(() => {}).
      finally(() => group.classList.remove("batch-builder__list__group--loading"))
  }

  updateDraft(event) {
    event.preventDefault()
    const form = event.target
    if (this.updating) { this.updating.abort() }
    const request = this.updating = new AbortController()
    this.busy()
    fetch(form.action, {
      method: "POST",
      body: new FormData(form),
      credentials: "same-origin",
      headers: backgroundHeaders(),
      signal: request.signal
    }).
      then((response) => { if (!response.ok) { throw new Error(response.statusText) } return response.text() }).
      then((html) => {
        this.draftTarget.innerHTML = html
        this.draftChanged()
      }).
      catch((error) => {
        if (error.name === "AbortError") { return }
        this.draftTarget.innerHTML = this.message("ajax-error", this.draftTarget.getAttribute("data-ajax-error-message"))
      }).
      finally(() => {
        if (this.updating === request) { this.updating = null }
        this.busy()
      })
  }

  draftChanged() {
    const wasFull = this.reachedLimit
    this.bodyIds = this.readBodyIds()
    this.reachedLimit = this.bodyIds.length >= this.limit
    this.updateDraftId()
    if (wasFull && !this.reachedLimit) {
      this.searchIfNeeded()
    } else if (wasFull !== this.reachedLimit) {
      this.renderResults()
    } else {
      this.refresh()
    }
  }

  readDraftId() {
    const summary = this.draftTarget.querySelector(".js-draft-batch-request-summary")
    return summary ? summary.getAttribute("data-draft-id") : null
  }

  readBodyIds() {
    return Array.from(this.draftTarget.querySelectorAll("form[data-body-id]")).
      map((form) => parseInt(form.getAttribute("data-body-id"), 10))
  }

  updateDraftId() {
    const draftId = this.readDraftId()
    if (draftId === this.draftId) { return }
    this.draftId = draftId
    // Preserve window.history.state so Turbo Drive history restoration stays intact.
    window.history.replaceState(window.history.state, "", this.withDraftId(window.location.href))
    this.modeLinkTargets.forEach((link) => { link.href = this.withDraftId(link.href) })
  }

  withDraftId(href) {
    const url = new URL(href, window.location.href)
    if (this.draftId) {
      url.searchParams.set("draft_id", this.draftId)
    } else {
      url.searchParams.delete("draft_id")
    }
    return url.toString()
  }

  refresh() {
    this.element.querySelectorAll(".js-draft-id").forEach((field) => { field.value = this.draftId || "" })
    this.resultsTarget.querySelectorAll(".js-batch-authority-search-results-list-item").forEach((item) => {
      const added = this.bodyIds.includes(parseInt(item.getAttribute("data-body-id"), 10))
      item.classList.toggle("js-batch-authority-search-results-list-item--added", added)
    })
    if (this.hasCountTarget) {
      const count = this.bodyIds.length
      const template = this.countTarget.getAttribute(
        count === 0 ? "data-message-template-zero" : count === 1 ? "data-message-template-one" : "data-message-template-many"
      )
      if (template) { this.countTarget.textContent = template.replace("{{count}}", count) }
    }
    if (this.hasWriteButtonTarget) {
      this.writeButtonTarget.disabled = !this.draftTarget.querySelector(".batch-builder__list__item")
    }
    this.busy()
  }

  busy() {
    const working = Boolean(this.searching || this.updating)
    this.builderTarget.classList.toggle("loading", Boolean(this.searching))
    this.draftTarget.classList.toggle("loading", Boolean(this.updating))
    this.element.querySelectorAll(".js-add-authority-to-batch-submit, .js-remove_authority-from-batch-submit").forEach((button) => {
      button.disabled = working
      if (working) { button.setAttribute("aria-disabled", "true") } else { button.removeAttribute("aria-disabled") }
    })
    this.resultsTarget.querySelectorAll(".pagination a").forEach((link) => {
      link.classList.toggle("disabled", working)
      if (working) { link.setAttribute("aria-disabled", "true") } else { link.removeAttribute("aria-disabled") }
    })
  }
}
