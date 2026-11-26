import { Controller } from "@hotwired/stimulus"

// Importing holidays: the feed URL only matters, and only takes input, when
// the feed is the source; and a suggested holiday can be left out of the
// import before it is sent.
export default class extends Controller {
  static targets = ["feedUrl"]

  connect() { this.source() }

  source() {
    if (!this.hasFeedUrlTarget) { return }
    const checked = this.element.querySelector("input[name='holiday_import[source]']:checked")
    this.feedUrlTarget.disabled = !!checked && checked.value === "suggestions"
  }

  remove(event) {
    event.preventDefault()
    const holiday = event.target.closest(".import-holiday-info")
    if (holiday) { holiday.remove() }
  }
}
