# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Composes, previews and queues an InfoRequestBatch from a trusted user's
# DraftInfoRequestBatch, checking request limits and duplicate batches.
class AlaveteliPro::InfoRequestBatchesController < AlaveteliPro::BaseController
  include RequestLimited

  read_only :requests, only: %i[new preview create]

  # Full load preserves typed text on Back (see doc/FORK.md).
  turbo_drive false, only: %i[new preview create]

  before_action :require_batch_permission

  def new
    @draft_info_request_batch = load_draft
    load_data_from_draft(@draft_info_request_batch)
    render 'alaveteli_pro/info_requests/new'
  end

  def preview
    @draft_info_request_batch = load_draft
    load_data_from_draft(@draft_info_request_batch)
    if all_models_valid?(ignore_existing_batch: true)
      render 'alaveteli_pro/info_requests/preview'
    else
      remove_duplicate_errors
      render 'alaveteli_pro/info_requests/new'
    end
  end

  def create
    @draft_info_request_batch = load_draft
    load_data_from_draft(@draft_info_request_batch)
    if all_models_valid?
      @info_request_batch.save!
      @draft_info_request_batch.destroy
      flash[:batch_sent] = true
      redirect_to show_alaveteli_pro_batch_request_path(
        id: @info_request_batch.id
      )
    elsif all_models_valid?(ignore_existing_batch: true)
      # Duplicate batch appeared since preview; re-render with override box.
      render 'alaveteli_pro/info_requests/preview',
             status: :unprocessable_content
    else
      remove_duplicate_errors
      render 'alaveteli_pro/info_requests/new', status: :unprocessable_content
    end
  rescue RequestLimits::Exceeded => e
    render_request_limit(e.refusal, draft: true)
  rescue RequestLimits::BatchesOff
    raise ActiveRecord::RecordNotFound
  end

  private

  def load_draft
    current_user.draft_info_request_batches.find(params[:draft_id])
  end

  def load_data_from_draft(draft)
    @info_request_batch = InfoRequestBatch.from_draft(draft)
    # We make an example request mainly so that we can get the outgoing message
    # from it. The outgoing message will have
    # a templated body from our template, allowing us to present a more
    # realistic preview to the user.
    # We can also use these objects to validate the batch, checking that it
    # will create valid requests against the constraints they have on subject
    # lines and body content.
    @example_info_request = @info_request_batch.example_request
    @outgoing_message = @example_info_request.outgoing_messages.first
  end

  def all_models_valid?(ignore_existing_batch: nil)
    ignore_existing_batch ||= params.fetch(:ignore_existing_batch, false)
    @info_request_batch.ignore_existing_batch = ignore_existing_batch

    @example_info_request.valid? && \
      @outgoing_message.valid? && \
      @info_request_batch.valid?
  end

  def remove_duplicate_errors
    # Tidy up the errors because there will be duplicates
    # When there's an error on the outgoing messages, it will also appear on
    # the request, so remove that version
    @example_info_request.errors.delete(:outgoing_messages)
    # Only drop batch :title error when example_request also flagged it; batch
    # length validation does not collapse whitespace like InfoRequest does.
    if @example_info_request.errors.include?(:title)
      @info_request_batch.errors.delete(:title)
    end
    @info_request_batch.errors.delete(:body) if @outgoing_message.errors.any?
  end
end
