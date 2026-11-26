module Disclosures
  # Applies a saved or deleted censor rule across matching FoiAttachments.
  class RuleJob < ApplicationJob
    queue_as :low

    BATCH = 50

    # Must match ApplicationJob's retry limit so bad files skip on the last try.
    TRIES = 5

    def self.start(rule, was_black: false)
      perform_later(rule.id, saved_at(rule), 'apply', 0, was_black)
    end

    def self.deleted(rule)
      perform_later(nil, nil, 'removed', 0, false,
                    rule.censorable_type, rule.censorable_id)
    end

    def self.saved_at(rule)
      rule.updated_at.utc.iso8601(6)
    end

    # unfinished stays true once any file is skipped, suppressing finish(rule).
    def perform(rule_id, saved_at = nil, stage = 'apply', after = 0,
                was_black = false, censorable_type = nil, censorable_id = nil,
                unfinished = false)
      @unfinished = unfinished
      if stage == 'removed'
        run_removed(censorable_type, censorable_id, after)
      else
        run_apply(rule_id, saved_at, stage, after, was_black)
      end
    end

    private

    def run_apply(rule_id, saved_at, stage, after, was_black)
      rule = CensorRule.find_by(id: rule_id) or return
      return unless self.class.saved_at(rule) == saved_at

      if stage == 'apply' && was_black
        last = remask_removed_batch(rule.censorable_type, rule.censorable_id,
                                    after, rule_id: rule_id)
        return carry_on(rule_id, saved_at, 'apply', last, true) if last

        return carry_on(rule_id, saved_at, 'remasked', 0, false)
      end

      last = apply_batch(rule, after)
      if last
        carry_on(rule_id, saved_at, stage, last, false)
      elsif !@unfinished
        finish(rule)
      end
    end

    def carry_on(rule_id, saved_at, stage, after, was_black)
      self.class.perform_later(rule_id, saved_at, stage, after, was_black,
                               nil, nil, @unfinished)
    end

    def run_removed(censorable_type, censorable_id, after)
      last = remask_removed_batch(censorable_type, censorable_id, after)
      return unless last

      self.class.perform_later(nil, nil, 'removed', last, false,
                               censorable_type, censorable_id)
    end

    def apply_batch(rule, after)
      batch = attachments_in_reach(rule.censorable_type, rule.censorable_id,
                                   public_only: rule.blue?).
        where('foi_attachments.id > ?', after).
        order('foi_attachments.id').limit(BATCH).to_a

      each_file(batch, rule.id) do |attachment|
        RuleRemask.apply_to_attachment!(attachment, rule)
      end
      batch.last.id if batch.size == BATCH
    end

    def remask_removed_batch(censorable_type, censorable_id, after,
                             rule_id: nil)
      batch = attachments_in_reach(censorable_type, censorable_id,
                                   public_only: false).
        where(black_masked: true).
        where.not(prominence: 'public').
        where('foi_attachments.id > ?', after).
        order('foi_attachments.id').limit(BATCH).to_a

      each_file(batch, rule_id) do |attachment|
        RuleRemask.remask_after_removal!(attachment)
      end
      batch.last.id if batch.size == BATCH
    end

    # Retries the batch until the final attempt, then reports and skips failing
    # files so one bad attachment cannot block the rest of the sweep.
    def each_file(batch, rule_id)
      batch.each do |attachment|
        yield attachment
      rescue StandardError => e
        raise if executions < TRIES

        @unfinished = true
        report_passed_over(attachment, rule_id, e)
      end
    end

    def report_passed_over(attachment, rule_id, error)
      Rails.logger.error("Disclosures::RuleJob #{rule_id || 'removed'}: " \
                         "attachment #{attachment.id} passed over " \
                         "(#{error.class})")
      return unless send_exception_notifications?

      ExceptionNotifier.notify_exception(
        error, data: { job: self.class.to_s, job_id: job_id,
                       censor_rule_id: rule_id,
                       attachment_id: attachment.id }
      )
    end

    def attachments_in_reach(censorable_type, censorable_id, public_only:)
      scope = FoiAttachment.not_erased
      scope = scope.where(prominence: 'public') if public_only

      live = live_request_attachment_ids(censorable_type, censorable_id)
      detached = detached_attachment_ids(censorable_type, censorable_id)

      if detached
        scope.where(id: live).or(scope.where(id: detached))
      else
        scope.where(id: live)
      end
    end

    def live_request_attachment_ids(censorable_type, censorable_id)
      requests = case censorable_type
                 when 'InfoRequest'
                   InfoRequest.where(id: censorable_id)
                 when 'PublicBody'
                   InfoRequest.where(public_body_id: censorable_id)
                 when 'User'
                   InfoRequest.where(user_id: censorable_id)
                 else
                   InfoRequest.unscoped
                 end
      FoiAttachment.joins(:incoming_message).
        where(incoming_messages: { info_request_id: requests.select(:id) }).
        select(:id)
    end

    def detached_attachment_ids(censorable_type, censorable_id)
      return if censorable_type == 'InfoRequest'

      docs = Document.where(request_deleted_at: ..Time.current)
      docs = case censorable_type
             when 'PublicBody' then docs.where(public_body_id: censorable_id)
             when 'User' then docs.where(owner_id: censorable_id)
             else docs
             end
      FoiAttachment.where(incoming_message_id: nil, prominence: 'public').
        joins(:disclosure_document).
        merge(docs).select(:id)
    end

    def finish(rule)
      CensorRule.where(id: rule.id, updated_at: rule.updated_at).
        update_all(masking_finished_at: Time.current)
    end
  end
end
