import { Controller } from "@hotwired/stimulus"

// Pro dashboard announcement carousel; CSS shows only the item with aria-hidden="false".
export default class extends Controller {
  static targets = ["item"]

  next() { this.show(this.offset(1)) }

  previous() { this.show(this.offset(-1)) }

  dismissed(event) {
    const item = event.target.closest("[data-carousel-target~='item']")
    const index = this.itemTargets.indexOf(item)
    if (item) { item.remove() }
    if (!this.itemTargets.length) {
      this.element.remove()
      return
    }
    this.show(Math.min(Math.max(index, 0), this.itemTargets.length - 1))
  }

  currentIndex() {
    const index = this.itemTargets.findIndex((item) => item.getAttribute("aria-hidden") === "false")
    return index < 0 ? 0 : index
  }

  offset(step) {
    const count = this.itemTargets.length
    return (this.currentIndex() + step + count) % count
  }

  show(index) {
    this.itemTargets.forEach((item, i) => {
      item.setAttribute("aria-hidden", i === index ? "false" : "true")
    })
    // The numbers sit inside a translated sentence, so are found by class.
    const current = this.element.querySelector(".current-page")
    const total = this.element.querySelector(".total-pages")
    if (current) { current.textContent = index + 1 }
    if (total) { total.textContent = this.itemTargets.length }
  }
}
