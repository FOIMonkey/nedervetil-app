// Cancel Turbo 8 visits for same-page hash links so the browser jumps natively
// without refetching and losing open UI state or focus.
export function jumpWithinPage(event) {
  const link = event.target
  const href = link.getAttribute && link.getAttribute("href")
  if (!href || !href.includes("#")) { return }

  const there = new URL(event.detail.url)
  const here = new URL(window.location.href)
  if (there.origin === here.origin && there.pathname === here.pathname &&
      there.search === here.search) {
    event.preventDefault()
  }
}
