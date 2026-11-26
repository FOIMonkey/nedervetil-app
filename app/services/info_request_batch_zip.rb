##
# This service streams a ZIP file with all incoming/ outgoing messages and
# attachments for each request for a given info request batch
#
class InfoRequestBatchZip
  include DownloadHelper
  include Enumerable

  ZippableFile = Struct.new(:path, :body)

  attr_reader :info_request_batch, :ability

  delegate :cannot?, to: :ability

  def initialize(info_request_batch, ability:)
    @info_request_batch = info_request_batch
    @ability = ability
  end

  def files
    to_a
  end

  def name
    generate_download_filename(
      resource: 'batch',
      id: info_request_batch.id,
      title: info_request_batch.title,
      type: 'export',
      ext: 'zip'
    )
  end

  def stream(&chunks)
    block_writer = ZipKit::BlockWrite.new(&chunks)

    ZipKit::Streamer.open(
      block_writer,
      auto_rename_duplicate_filenames: true
    ) do |zip|
      each do |file|
        zip.write_deflated_file(file.path) { |writer| writer << file.body }
      end
    end
  end

  private

  def each(&_block)
    yield prepare_dashboard_metrics

    info_request_events.each do |event|
      if event.outgoing?
        message = prepare_outgoing_message(event.outgoing_message)
        yield message if message

      elsif event.response?
        yield_incoming(event.incoming_message) { |item| yield item }
      end
    end
  end

  def yield_incoming(incoming_message)
    return if cannot?(:read, incoming_message)

    # Raises for a reply whose mail can't be read now, where its text
    # would be a note and listing its attachments would leave them out.
    return unless incoming_message.parse_raw_email_if_there

    message = prepare_incoming_message(incoming_message)
    yield message if message

    incoming_message.get_attachments_for_display.each do |attachment|
      attachment = prepare_foi_attachment(attachment)
      yield attachment if attachment
    end
  end

  def info_request_events
    readable = info_request_batch.readable_info_requests(ability)
    InfoRequestEvent.where(info_request: readable).
      includes(:info_request, info_request: [:public_body]).
      includes(:outgoing_message).
      includes(:incoming_message, incoming_message: [:foi_attachments])
  end

  def prepare_dashboard_metrics
    metrics = InfoRequestBatchMetrics.new(info_request_batch, ability: ability)
    ZippableFile.new(metrics.name, metrics.to_csv)
  end

  def prepare_outgoing_message(message)
    return if cannot?(:read, message)

    sent_at = message.last_sent_at.to_formatted_s(:filename)
    name = "outgoing_#{message.id}.txt"
    path = [base_path(message.info_request), sent_at, name].join('/')

    ZippableFile.new(path, message.body)
  end

  def prepare_incoming_message(message)
    return if cannot?(:read, message)

    body_part = message.get_main_body_text_part
    return if body_part && cannot?(:read, body_part)

    sent_at = message.sent_at.to_formatted_s(:filename)
    name = "incoming_#{message.id}.txt"
    path = [base_path(message.info_request), sent_at, name].join('/')

    ZippableFile.new(path, message.main_body_text!)
  end

  def prepare_foi_attachment(attachment)
    message = attachment.incoming_message
    return if cannot?(:read, message)
    return if cannot?(:read, attachment)

    sent_at = message.sent_at.to_formatted_s(:filename)

    path = [
      base_path(message.info_request),
      sent_at,
      "attachments-#{message.id}",
      safe_zip_component(attachment.display_filename)
    ].join('/')

    ZippableFile.new(path, attachment.masked_default_body)
  end

  def base_path(info_request)
    [safe_zip_component(info_request.public_body.name),
     safe_zip_component(info_request.url_title)].join(' - ')
  end

  def safe_zip_component(value)
    component = value.to_s.gsub(%r{[/\\:\x00-\x1f]+}, '_')
    %w[. ..].include?(component) ? '_' : component
  end
end
