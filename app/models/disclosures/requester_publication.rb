module Disclosures
  # Requester self-publishing path for one-file disclosure documents.
  module RequesterPublication
    Problem = Struct.new(:text, :fix, :pages, keyword_init: true)
    PREPARING = N_('Getting the file ready.').freeze
    WITH_ADMIN = N_('An admin checks this one before it can go public.').freeze

    module_function

    def problems(document, _version = nil)
      return [Problem.new(text: _('It has been erased.'))] if document.erased?
      unless document.servable?
        return [Problem.new(text: _(PREPARING), fix: :wait)]
      end
      if document.foi_attachment&.black_masked?
        return [Problem.new(text: _(WITH_ADMIN), fix: :admin)]
      end

      []
    end

    def publish_all!(documents, user:, **_ignored)
      ActiveRecord::Base.transaction(requires_new: true) do
        documents.map { |document| publish!(document, user: user) }
      end
    end

    def publish!(document, user:, **_ignored)
      document.with_lock do
        unless Ability.new(user).can?(:publish_own_document, document)
          raise Error::Refused, _('You can’t publish that document now.')
        end

        return :published if document.listed?

        if ReviewSubmission.required?(document)
          return ReviewSubmission.submit!(document, user: user)
        end

        if (problem = problems(document).first)
          raise Error::Refused, "“#{document.title}”: #{problem.text}"
        end

        publish_or_queue!(document, user)
      end
    end

    def publish_or_queue!(document, user)
      Publication.new(document, user: user).publish!
      :published
    rescue Error::NeedsAdmin => e
      ReviewSubmission.submit!(document, user: user, reason: e.message)
    end

    def pages(numbers)
      n_('page {{pages}}',
         'pages {{pages}}',
         numbers.size,
         pages: Checks.page_list(numbers.sort))
    end
  end
end
