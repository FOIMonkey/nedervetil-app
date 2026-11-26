export function csrfParam() {
  const meta = document.querySelector('meta[name="csrf-param"]')
  return meta ? meta.content : null
}

export function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]')
  return meta ? meta.content : null
}

// Same-origin fetch headers for Rails request.xhr? checks and CSRF verification.
export function backgroundHeaders(extra = {}) {
  const headers = { "X-Requested-With": "XMLHttpRequest", ...extra }
  const token = csrfToken()
  if (token) { headers["X-CSRF-Token"] = token }
  return headers
}
