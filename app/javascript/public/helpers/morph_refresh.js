// Restrict Turbo morphs to #content (preserving open <details>) and reconnect touched controllers
// so they rebuild stripped markup. Stimulus reuses instances, so disconnect() must clean up (doc/FORK.md).

const touched = new Set()

function content() {
  return document.getElementById("content")
}

document.addEventListener("turbo:before-morph-element", (event) => {
  const element = event.target
  const main = content()
  if (!main || main.contains(element) || element.contains(main)) { return }
  event.preventDefault()
})

document.addEventListener("turbo:before-morph-attribute", (event) => {
  const { attributeName, mutationType } = event.detail
  if (event.target.tagName === "DETAILS" && attributeName === "open" && mutationType === "remove") {
    event.preventDefault()
  }
})

document.addEventListener("turbo:morph-element", (event) => {
  const element = event.target
  const main = content()
  if (main && main !== element && main.contains(element) && element.hasAttribute("data-controller")) {
    touched.add(element)
  }
})

// Yield a tick so Stimulus observes attribute removal and disconnect/connects each controller.
document.addEventListener("turbo:morph", () => {
  const restarting = Array.from(touched, (element) => [element, element.getAttribute("data-controller")])
  touched.clear()
  restarting.forEach(([element]) => element.removeAttribute("data-controller"))
  window.setTimeout(() => {
    restarting.forEach(([element, names]) => {
      if (element.isConnected) { element.setAttribute("data-controller", names) }
    })
  }, 0)
})
