// Swap an element's content for a short message ("Copied!"), then put
// back what was there. Calling it again while the message shows starts the
// wait again rather than saving the message as the original.
const originals = new WeakMap()
const timers = new WeakMap()

export function showBriefly(element, message, milliseconds = 3000) {
  if (!originals.has(element)) { originals.set(element, element.innerHTML) }
  element.textContent = message
  window.clearTimeout(timers.get(element))
  timers.set(element, window.setTimeout(() => {
    element.innerHTML = originals.get(element)
    originals.delete(element)
    timers.delete(element)
  }, milliseconds))
}
