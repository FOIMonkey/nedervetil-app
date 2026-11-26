# View helpers for the two factor authentication setup flow.
module OneTimePasswordsHelper
  def otp_provisioning_qr_code(provisioning_uri)
    # rubocop:disable Rails/OutputSafety -- RQRCode draws the SVG: paths and numbers, with none of the address's text in it
    raw RQRCode::QRCode.new(provisioning_uri).as_svg(
      module_size: 5,
      use_path: true
    )
    # rubocop:enable Rails/OutputSafety
  end
end
