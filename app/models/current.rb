# Values for the current request or job, which Rails resets after each.
class Current < ActiveSupport::CurrentAttributes
  # Per-page cache; nil outside Current.memoising so nothing is retained.
  attribute :page_memo

  # Stops further email reads on this page once one is refused.
  attribute :mail_read_refused
  # Remaining page budget in seconds for email reads (MailHandler::Reading).
  attribute :mail_read_left

  def memoising(&block)
    set(page_memo: page_memo || {}, &block)
  end

  def without_memo(&block)
    set(page_memo: nil, &block)
  end

  def memo(*key)
    return yield unless page_memo

    # Key relations by SQL because equal relations are distinct objects.
    key = key.map { |part| part.respond_to?(:to_sql) ? part.to_sql : part }
    page_memo.fetch(key) { page_memo[key] = yield }
  end
end
