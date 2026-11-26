// Bypass Turbo Drive for admin and turbo_drive=false pages (doc/FORK.md) to avoid
// a wasted fetch before Turbo falls back to a full reload. Keep in sync with the opt-out list.
const FULL_LOAD = [
  /^\/admin(\/|$)/,
  /^\/pro\/(info_requests|info_request_batches)\/new(\/|$)/,
  /^\/manage\/attachments\//,
  /^\/documents\/[^/]+\/(redact|versions|manage)(\/|$)/,
  /^\/request\/[^/]+\/publish\/[^/]+\/redact$/,
  /^\/new(\/|$)/,
  /^\/request\/[^/]+\/followups\/new(\/|$)/,
  /\/report\/new$/
]

export function loadInFull(event) {
  const url = new URL(event.detail.url)
  if (url.origin !== window.location.origin) { return }
  if (FULL_LOAD.some((pattern) => pattern.test(url.pathname))) {
    event.preventDefault()
  }
}
