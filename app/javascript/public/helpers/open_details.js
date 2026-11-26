// Opens enclosing <details> immediately (data-opened-by-page suppresses the
// features/_motion.scss transition so focus can move into the revealed content).
export function openAround(element) {
  for (let details = element.closest("details"); details;
    details = details.parentElement && details.parentElement.closest("details")) {
    if (details.open) continue
    details.setAttribute("data-opened-by-page", "")
    details.open = true
    const opened = details
    requestAnimationFrame(() => requestAnimationFrame(() => opened.removeAttribute("data-opened-by-page")))
  }
}
