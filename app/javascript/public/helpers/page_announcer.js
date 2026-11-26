// Announce Turbo Drive visits and manage focus (restoration, 4xx errors, morph data-lands-on).

import { openAround } from "helpers/open_details"

let visitAction = null
let failedSubmit = false
let morphed = false
let landsOn = null

document.addEventListener("turbo:visit", (event) => {
  visitAction = event.detail.action
})

// A form submit starts afresh, whatever visit came before.
document.addEventListener("turbo:submit-start", (event) => {
  visitAction = null
  landsOn = event.target.getAttribute("data-lands-on")
})

document.addEventListener("turbo:submit-end", (event) => {
  const response = event.detail.fetchResponse
  failedSubmit = Boolean(response) &&
    response.statusCode >= 400 && response.statusCode < 500
})

// A failed submit renders without a visit, so there's no turbo:load.
document.addEventListener("turbo:render", (event) => {
  morphed = event.detail.renderMethod === "morph"
  if (morphed || visitAction || !failedSubmit) { return }
  failedSubmit = false
  landsOn = null
  window.setTimeout(focusErrors, 0)
})

document.addEventListener("turbo:load", () => {
  const action = visitAction
  const refreshed = morphed
  const landing = landsOn
  visitAction = null
  failedSubmit = false
  morphed = false
  landsOn = null
  // Wait for controllers to reconnect before focusing the form's landing spot.
  if (refreshed) {
    if (landing) { window.setTimeout(() => landAfterRefresh(landing), 0) }
    return
  }
  // A full page load: the browser has done all this itself.
  if (!action) { return }

  announce(document.title)
  // Defer past flash-focus controller so notices keep focus.
  if (action !== "restore") { window.setTimeout(focusStart, 0) }
})

function announce(text) {
  const region = document.getElementById("page-announcer")
  if (!region) { return }
  // Emptied first, so the same title twice is still read out.
  region.textContent = ""
  window.setTimeout(() => { region.textContent = text }, 100)
}

function landAfterRefresh(id) {
  const target = document.getElementById(id)
  if (target) {
    openAround(target)
    focusOnce(target)
    target.scrollIntoView({ block: "nearest" })
  }
  const notice = document.querySelector("#content #notice, #content #error, #content .band-flash")
  const words = notice && notice.textContent.trim()
  if (words) { announce(words) }
}

function focusIsFree() {
  const active = document.activeElement
  return !active || active === document.body || active === document.documentElement
}

function focusStart() {
  if (focusIsFree()) { focusOnce(document.body) }
}

function focusErrors() {
  // Turbo's autofocus wins here too.
  if (!focusIsFree()) { return }
  const summary = document.querySelector("#errorExplanation, #error")
  if (summary) {
    focusOnce(summary)
  } else {
    focusStart()
  }
}

// Give a non-control temporary focus without adding it to the Tab order.
function focusOnce(element) {
  if (!element.hasAttribute("tabindex")) {
    element.setAttribute("tabindex", "-1")
    element.style.outline = "none"
    element.addEventListener("blur", () => {
      element.removeAttribute("tabindex")
      element.style.removeProperty("outline")
    }, { once: true })
  }
  element.focus({ preventScroll: true })
}
