# Serializes topic and guide writes under TopicChange.take_turn so reference
# checks and history ids reflect commit order; rolls back any write that
# introduces new broken Topics::References.
module TopicChange::Checked
  def save(**)
    in_turn('saved') { super }
  end

  def save!(**)
    in_turn('saved') { super } || raise(ActiveRecord::RecordInvalid, self)
  end

  def destroy
    in_turn('deleted') { super }
  end

  private

  # Nested writes skip per-row checks; the outermost write validates all.
  def in_turn(done)
    TopicChange.transaction(requires_new: true) do
      TopicChange.take_turn
      next yield if Current.topic_write

      Current.set(topic_write: true) do
        before = Topics::References.broken
        result = yield
        added = result ? Topics::References.broken.except(*before.keys) : {}
        next result if added.empty?

        added.each_value do |problem|
          errors.add(:base, "It can’t be #{done}: #{problem}")
        end
        raise ActiveRecord::Rollback
      end
    end || false
  end
end
