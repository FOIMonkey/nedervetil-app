::SecureHeaders::Configuration.default do |config|
  # HSTS is sent by config.force_ssl in production (and by nginx at the
  # edge); a third copy here would be one more place to keep in step.
  config.hsts = SecureHeaders::OPT_OUT

  # https://tools.ietf.org/html/draft-ietf-websec-x-frame-options-02
  config.x_frame_options = "sameorigin"

  # http://msdn.microsoft.com/en-us/library/ie/gg622941%28v=vs.85%29.aspx
  config.x_content_type_options = "nosniff"

  # Browsers have dropped the XSS auditor; the header is deprecated and the
  # filter it enabled could itself leak page content in old browsers.
  config.x_xss_protection = SecureHeaders::OPT_OUT

  # https://w3c.github.io/webappsec/specs/content-security-policy/
  config.csp = SecureHeaders::OPT_OUT

  # https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Referrer-Policy
  config.referrer_policy = 'strict-origin-when-cross-origin'

  # https://www.nwebsec.com/HttpHeaders/SecurityHeaders/XDownloadOptions
  config.x_download_options = SecureHeaders::OPT_OUT

  # https://github.com/github/secureheaders/blob/master/docs/cookies.md
  # Note the secure flag is only sent where HTTPS is available
  config.cookies = {
    httponly: { only: ['_wdtk_cookie_session'] },
    secure: { only: ['_wdtk_cookie_session'] },
    samesite: {
      lax: { only: ['_wdtk_cookie_session'] }
    }
  }
end

# Allow individual actions to allow frames
::SecureHeaders::Configuration.override(:allow_frames) do |config|
  config.x_frame_options = SecureHeaders::OPT_OUT
end

# Token and enrolment pages never disclose their address in a Referer: a
# Referer from them carries only the site's origin, never the path. Not
# no-referrer, because under that browsers send `Origin: null` on these
# pages' own signed-out forms, and verify_signed_out_origin refuses them.
::SecureHeaders::Configuration.override(:authentication) do |config|
  config.referrer_policy = 'strict-origin'
end
