import { Controller } from "@hotwired/stimulus"
import { daysBetween, gapText } from "helpers/thread_gaps"

// Inserts day-gap labels and sidebar attachment index (data-uncached).
// Morph refreshes reuse this instance, so disconnect() must remove added nodes (helpers/morph_refresh).
export default class extends Controller {
  connect() {
    this.added = []
    const messages = Array.from(this.element.querySelectorAll(".correspondence"))
    this.markGaps(messages)
    this.listAttachments()
  }

  disconnect() {
    this.added.forEach((node) => node.remove())
    this.added = []
  }

  timeOf(message) {
    return message.querySelector(".correspondence__header time")
  }

  markGaps(messages) {
    messages.forEach((message, index) => {
      if (index === 0) { return }
      const before = this.timeOf(messages[index - 1])
      const after = this.timeOf(message)
      if (!before || !after) { return }

      const days = daysBetween(before.getAttribute("datetime"), after.getAttribute("datetime"))
      if (days === null) { return }

      const gap = document.createElement("p")
      gap.className = "thread-gap"
      gap.setAttribute("data-uncached", "")
      gap.textContent = gapText(days)
      message.parentNode.insertBefore(gap, message)
      this.added.push(gap)
    })
  }

  listAttachments() {
    const sidebar = document.getElementById("right_column")
    const attachments = Array.from(this.element.querySelectorAll(".attachment[id]"))
    if (!sidebar || !attachments.length) { return }

    const list = document.createElement("ol")
    attachments.forEach((attachment) => {
      const item = this.attachmentItem(attachment)
      if (item) { list.appendChild(item) }
    })
    if (!list.children.length) { return }

    const heading = document.createElement("h2")
    heading.textContent = "Attachments"

    const section = document.createElement("div")
    section.className = "sidebar__section sidebar__documents"
    section.setAttribute("data-uncached", "")
    section.append(heading, list)
    const published = sidebar.querySelector(".sidebar__request-documents")
    sidebar.insertBefore(section, published ? published.nextSibling : sidebar.firstChild)
    this.added.push(section)
  }

  attachmentItem(attachment) {
    const nameEl = attachment.querySelector(".attachment__name")
    const metaEl = attachment.querySelector(".attachment__meta")
    if (!nameEl) { return null }

    const name = nameEl.textContent.trim()
    const dot = name.lastIndexOf(".")
    const type = dot > 0 && name.length - dot <= 6 ? name.slice(dot + 1).toUpperCase() : ""
    // The size is the first thing in the meta line, before the links.
    const size = metaEl && metaEl.firstChild ? metaEl.firstChild.textContent.trim() : ""
    const message = attachment.closest(".correspondence")
    const time = message ? this.timeOf(message) : null

    const link = document.createElement("a")
    link.href = `#${attachment.id}`
    link.textContent = name

    const meta = document.createElement("span")
    meta.className = "sidebar__documents__meta"
    if (type) {
      const label = document.createElement("b")
      label.textContent = type
      meta.append(label, " ")
    }
    meta.append([size, time ? time.textContent.trim() : ""].filter(Boolean).join(" · "))

    const item = document.createElement("li")
    item.append(link, meta)
    return item
  }
}
