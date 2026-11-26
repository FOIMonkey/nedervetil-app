import { Controller } from "@hotwired/stimulus"

// Branching refusal advice wizard driven by data-show-if and prefilled from data-refusals.
export default class extends Controller {
  static values = { expandText: String, shrinkText: String }

  connect() {
    this.form = this.element.querySelector("form")
    this.questions = Array.from(this.element.querySelectorAll(".wizard__question"))
    this.suggestions = Array.from(this.element.querySelectorAll(".wizard__suggestion"))
    this.actions = Array.from(this.element.querySelectorAll(".wizard__action"))
    this.nextSteps = Array.from(this.element.querySelectorAll(".wizard__next-step"))

    this.questions.forEach((question) => this.reset(question))
    this.answerRecorded()
    this.update()
    this.foldExemptions()
  }

  answer(event) {
    const question = event.target.closest(".wizard__question")
    if (question && event.target.matches("input.wizard__question__option")) { this.update(question) }
  }

  toggleStep(event) {
    event.preventDefault()
    const action = event.target.closest(".wizard__next-step").querySelector(".wizard__action")
    const active = action.classList.contains("wizard__action--active")
    this.actions.forEach((each) => each.classList.remove("wizard__action--active"))
    if (!active) { action.classList.add("wizard__action--active") }
  }

  block(element) { return element.getAttribute("data-block") }

  showIf(element) {
    try { return JSON.parse(element.getAttribute("data-show-if") || "null") } catch (_) { return null }
  }

  options(element) {
    return Array.from(element.querySelectorAll("input.wizard__question__option"))
  }

  values(question) {
    return this.options(question).filter((input) => input.checked).map((input) => input.value)
  }

  dependentsOf(blocks, question) {
    return blocks.filter((block) => {
      if (this.options(block).some((input) => input.checked)) { return false }
      const conditions = this.showIf(block)
      if (!conditions) { return true }
      return conditions.some((condition) =>
        condition.id === this.block(question) &&
        condition.operator === "is" &&
        this.values(question).includes(condition.value)
      )
    })
  }

  dependents(blocks) {
    const found = []
    this.questions.forEach((question) => {
      this.dependentsOf(blocks, question).reverse().forEach((block) => {
        if (!found.includes(block)) { found.unshift(block) }
      })
    })
    return found
  }

  update(current) {
    const next = this.dependents(this.questions)[0]

    if (current) {
      current.classList.remove("wizard__question--answerable")
      current.classList.add("wizard__question--answered")
      // Reset downstream questions invalidated by changing this answer.
      let sibling = current.nextElementSibling
      while (sibling) {
        if (sibling.matches(".wizard__question")) { this.reset(sibling) }
        sibling = sibling.nextElementSibling
      }
    }

    if (next) {
      next.classList.add("wizard__question--answerable")
      const yes = next.querySelector('input.wizard__question__option[value="yes"]')
      if (yes) { yes.focus() }
    }

    if (current && next) { current.after(next) }

    const suggested = this.dependents(this.suggestions)
    this.actions.forEach((action) => action.classList.remove("wizard__action--suggested"))
    this.suggestions.forEach((suggestion) => suggestion.classList.remove("wizard__suggestion--suggested"))
    this.nextSteps.forEach((step) => step.classList.remove("wizard__next-step--suggested"))

    suggested.forEach((suggestion) => suggestion.classList.add("wizard__suggestion--suggested"))
    this.actions.forEach((action) => {
      if (!action.querySelector(".wizard__suggestion--suggested")) { return }
      action.classList.add("wizard__action--suggested")
      this.nextSteps.
        filter((step) => this.block(step) === this.block(action)).
        forEach((step) => step.classList.add("wizard__next-step--suggested"))
    })

    this.actions.forEach((action) => {
      action.querySelectorAll('input[name^="refusal_advice"]').forEach((input) => { input.value = "false" })
    })
    suggested.forEach((suggestion) => {
      suggestion.querySelectorAll('input[name^="refusal_advice"]').forEach((input) => { input.value = "true" })
    })
  }

  reset(question) {
    question.classList.remove("wizard__question--answerable", "wizard__question--answered")
    this.options(question).forEach((input) => { input.checked = false })
  }

  answerRecorded() {
    let refusals
    try { refusals = JSON.parse((this.form && this.form.getAttribute("data-refusals")) || "null") } catch (_) { return }
    if (!Array.isArray(refusals)) { return }
    const inputs = this.questions.flatMap((question) => this.options(question))
    refusals.forEach((refusal) => {
      inputs.filter((input) => input.value === refusal).forEach((input) => input.click())
    })
  }

  foldExemptions() {
    const block = this.element.querySelector('[data-block="exemption"]')
    if (!block) { return }
    const boxes = block.querySelectorAll('input[type="checkbox"]')
    if (boxes.length < 4) { return }

    const fieldset = block.querySelector("fieldset")
    // Reset expanded state on Turbo cache restore (button is data-uncached).
    block.classList.remove("expanded")
    this.expander = document.createElement("button")
    this.expander.setAttribute("data-uncached", "")
    this.expander.type = "button"
    this.expander.className = "button-secondary maximise-questions"
    this.expander.textContent = this.expandTextValue
    this.expander.setAttribute("aria-expanded", "false")
    this.expander.addEventListener("click", (event) => {
      event.preventDefault()
      this.toggleExemptions(block)
    })
    fieldset.after(this.expander)

    if (Array.from(boxes).some((box) => box.checked)) { this.toggleExemptions(block) }
  }

  toggleExemptions(block) {
    const expanded = block.classList.toggle("expanded")
    this.expander.textContent = expanded ? this.shrinkTextValue : this.expandTextValue
    this.expander.setAttribute("aria-expanded", String(expanded))
  }
}
