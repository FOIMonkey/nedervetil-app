module Disclosures
  # Categorises a reply's publishable documents for the check step; lists are
  # memoised lazily so waiting pages don't evaluate problems.
  class PublishCheck
    attr_reader :documents

    def initialize(documents)
      @documents = documents
    end

    def to_publish
      @to_publish ||= documents.all.select do |document|
        documents.ability.can?(:publish_own_document, document) &&
          (document.stage_in?(:held, :in_review, :not_ready, :ready) ||
           document.unpublished_changes?)
      end
    end

    def preparing
      @preparing ||= to_publish.reject { |document| documents.ready?(document) }
    end

    def stuck
      preparing.any?(&:processing?) ? [] : preparing
    end

    def problems
      @problems ||= to_publish.to_h do |document|
        [document, RequesterPublication.problems(document)]
      end
    end

    def pending
      @pending ||= to_publish.select do |document|
        ReviewSubmission.pending?(document)
      end
    end

    def review
      @review ||= begin
        preload(foi_attachment: :applied_revisions)
        (to_publish - pending).select do |document|
          document.servable? &&
            ReviewSubmission.required?(document, problems: problems[document])
        end
      end
    end

    def ready
      @ready ||= (to_publish - review - pending).select do |document|
        problems[document].empty?
      end
    end

    def attributions
      preload(foi_attachment: :applied_revisions)
      to_publish.index_with { |document| Attribution.new(document) }
    end

    def name_hits
      @name_hits ||= begin
        preload(:pages)
        to_publish.to_h { |document| [document, Checks.personal(document)] }
      end
    end

    def hide_name
      @hide_name ||= to_publish.index_with do |document|
        can_hide_name?(document)
      end
    end

    def can_hide_name?(document)
      return false unless documents.ability.can?(:redact_document, document)
      return false if ReviewSubmission.pending?(document)
      return false if name_hits[document].blank?

      attachment = document.foi_attachment
      return false unless maskable_file?(attachment)

      format = Formats.declared(attachment.content_type, attachment.filename)
      NameMask.maskable?(attachment, format, document: document)
    end

    def title
      if to_publish.empty?
        _('Nothing to share')
      elsif (to_publish - pending).empty?
        _('Waiting for admin review')
      else
        _('Anything to hide?')
      end
    end

    def waiting_title
      if stuck.any?
        _('Couldn’t get it ready')
      else
        n_('Getting it ready', 'Getting them ready', to_publish.size)
      end
    end

    private

    def preload(associations)
      ActiveRecord::Associations::Preloader.
        new(records: to_publish, associations: associations).call
    end

    def maskable_file?(attachment)
      return false unless attachment&.file&.attached? &&
                          !attachment.black_masked?
      return false if attachment.rasterized?

      true
    end
  end
end
