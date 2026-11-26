import { Controller } from "@hotwired/stimulus"

// The search box on the help front page. It fetches the answers once, on
// first use, and filters them in the browser: nothing typed is sent anywhere.
// Without JavaScript the box stays hidden and the sections are browsed.
export default class extends Controller {
  static targets = ["box", "input", "found", "browse"]
  static values = {
    index: String, contact: String, none: String, try: String,
    contactLabel: String
  }

  connect() {
    this.answers = null
    this.loading = false
    this.boxTarget.hidden = false
    // Back can show Turbo's copy of the page with words still in the box.
    this.show()
  }

  load() {
    if (this.answers || this.loading) { return }
    this.loading = true
    fetch(this.indexValue).
      then((response) => response.json()).
      then((rows) => { this.answers = rows; this.show() }).
      catch(() => {
        this.boxTarget.hidden = true
        this.browseTarget.hidden = false
        this.foundTarget.replaceChildren()
      })
  }

  show() {
    const words = this.plain(this.inputTarget.value).split(/\s+/).filter(Boolean)
    this.browseTarget.hidden = words.length > 0
    if (!words.length) { this.foundTarget.replaceChildren(); return }
    if (!this.answers) { this.load(); return }

    const hits = this.answers.filter((answer) => {
      const text = this.plain(`${answer.question} ${answer.short} ${answer.text}`)
      return words.every((word) => text.includes(word))
    })
    this.foundTarget.replaceChildren(hits.length ? this.list(hits) : this.none())
  }

  // The text has curly apostrophes, and keyboards type straight ones.
  plain(text) {
    return text.toLowerCase().replace(/[‘’]/g, "'")
  }

  list(hits) {
    const list = document.createElement("ul")
    list.className = "help-rows"
    hits.forEach((answer) => {
      const link = document.createElement("a")
      link.href = answer.url
      link.textContent = answer.question
      const short = document.createElement("small")
      short.textContent = answer.short
      link.append(short)
      const item = document.createElement("li")
      item.append(link)
      list.append(item)
    })
    return list
  }

  none() {
    const none = document.createElement("p")
    none.className = "help-none"
    const said = document.createElement("b")
    said.textContent = `${this.noneValue} “${this.inputTarget.value}”`
    const contact = document.createElement("a")
    contact.href = this.contactValue
    contact.textContent = this.contactLabelValue
    none.append(said, document.createElement("br"), `${this.tryValue} `,
                contact, ".")
    return none
  }
}
