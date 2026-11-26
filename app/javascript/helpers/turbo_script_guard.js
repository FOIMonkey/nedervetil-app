// Turbo copies body scripts. With strict-dynamic, those copies can inherit
// trust, so evaluate only scripts bearing the current page nonce.
export function guardTurboScripts(event) {
  const meta = document.head.querySelector('meta[name="csp-nonce"]')
  const nonce = meta ? meta.content : ""

  for (const script of event.detail.newBody.querySelectorAll("script")) {
    if (!nonce || script.nonce !== nonce) {
      script.setAttribute("data-turbo-eval", "false")
    }
  }
}

export function guardTurboFrameScripts(event) {
  for (const script of event.detail.newFrame.querySelectorAll("script")) {
    script.setAttribute("data-turbo-eval", "false")
  }
}

// Prepare stream content before Turbo inserts it into the page.
export function guardTurboStreamScripts(event) {
  for (const script of event.detail.newStream.templateElement.content.querySelectorAll("script")) {
    script.remove()
  }
}
