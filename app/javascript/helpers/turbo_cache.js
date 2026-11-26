// Strip data-uncached markup from snapshots before controllers reconnect.
// Avoid data-turbo-temporary: same-page anchor visits would strip it from the
// visible page too. Controllers reset their opened UI on connect (doc/FORK.md).

// Restoration may fetch fresh HTML, especially for uncached signed-in pages.
// Turbo has checked its cache by turbo:visit; a form submit resets this state.
let restoring = false
document.addEventListener("turbo:visit", (event) => {
  const visit = visitInProgress()
  restoring = event.detail.action === "restore" &&
    Boolean(visit && visit.hasCachedSnapshot())
})
document.addEventListener("turbo:submit-start", () => { restoring = false })
document.addEventListener("turbo:load", () => {
  // After the controllers the visit connected have asked fromCache().
  window.setTimeout(() => { restoring = false }, 0)
})

// Controllers must preserve restored focus and scroll when showing a snapshot.
export function fromCache() {
  return restoring ||
    document.documentElement.hasAttribute("data-turbo-preview")
}

// Anchor visits linger in currentVisit; callers must check isSamePage.
export function visitInProgress() {
  return window.Turbo && window.Turbo.navigator && window.Turbo.navigator.currentVisit
}

document.addEventListener("turbo:before-render", (event) => {
  if (!fromCache()) { return }
  event.detail.newBody.querySelectorAll("[data-uncached]").forEach((element) => element.remove())
})

export function driveOn() {
  return Boolean(window.Turbo && window.Turbo.session.drive) &&
    !document.body.closest('[data-turbo="false"]')
}
