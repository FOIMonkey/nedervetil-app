module BoundedAttentionHelpers
  def bounded_input(body = 'Synthetic state.', filenames: [], images: 0, available: true)
    metadata = { 'attachment_filenames_available' => available,
                 'non_image_attachment_filenames' => filenames,
                 'image_attachments_ignored' => images }
    text, shortened = IncomingAttention::Input.prepare(body, metadata)
    IncomingAttention::Config.contract.merge(
      'message_id' => '1',
      'info_request_id' => '2',
      'body' => text,
      'body_shortened' => shortened,
      'attachments' => { 'available' => available,
                         'filenames' => filenames,
                         'images_ignored' => images }
    )
  end

  # A Worker v5 answer; diagnostics are opaque here.
  def bounded_worker_response(input, route: 'SKIP', eligible: true, labels: { 'routine' => nil, 'attention' => nil }, truncated: nil)
    truncated = input['body_shortened'] if truncated.nil?
    input.slice('contract_version', 'message_id', 'info_request_id').merge(
      'inference_status' => 'complete',
      'route' => route,
      'needs_check' => route != 'SKIP',
      'eligibility' => eligible && !truncated,
      'input_truncated' => truncated,
      'labels' => labels,
      'diagnostics' => { 'model' => 'clef',
                         'answers' => { 'opaque' => true } },
      'error_code' => nil
    )
  end
end
RSpec.configure { |config| config.include BoundedAttentionHelpers }
