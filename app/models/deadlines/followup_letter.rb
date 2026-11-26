module Deadlines
  # Builds follow-up and review letter bodies wrapped in core's greeting and
  # sign-off. Scottish reviews require stating grounds of dissatisfaction
  # (FOISA s.20(3)(c); EIR(S) reg 16(2)).
  module FollowupLetter
    # key => [choice, the sentence it adds]
    REASONS = {
      'late' => [N_('They didn’t answer in time'),
                 N_('I did not receive a response within the 20 working ' \
                    'days the law allows.')],
      'part' => [N_('They held some back'),
                 N_('You held back part of the information I asked for. ' \
                    'Please release it, or explain why each part is ' \
                    'withheld.')],
      'all' => [N_('They said no to all of it'),
                N_('You refused my request. Please release the ' \
                   'information, or explain why each part is withheld.')],
      'none' => [N_('They say they don’t have it'),
                 N_('You say you do not hold the information. Please ' \
                    'check again, and tell me what searches you made.')],
      'other' => [N_('Something else'), nil]
    }.freeze

    module_function

    def long(date)
      I18n.l(date.to_date, format: '%-d %B %Y')
    end

    def sent_on(request)
      Stage.response_basis(request)&.created_at || request.created_at
    end

    def review(request, answered_on)
      answer = if answered_on
                 PlainTextTranslation._(
                   'I am not satisfied with your response of {{date}}, and ' \
                   'ask you to look at it again.',
                   date: long(answered_on)
                 )
               else
                 PlainTextTranslation._(
                   'I am not satisfied with how you handled it, and ask you ' \
                   'to look at it again.'
                 )
               end
      opening = PlainTextTranslation._(
        'Please pass this to the person who conducts internal reviews.'
      )
      body = PlainTextTranslation._(
        'I am writing to request an internal review of ' \
        "{{authority}}'s handling of my request \"{{title}}\", sent on " \
        '{{date}}.',
        authority: request.public_body.name,
        title: request.title,
        date: long(sent_on(request))
      )
      "#{opening}\n\n#{body}\n\n#{answer}"
    end

    def scottish_review(request, reason, more)
      [scottish_opening(request),
       (sentence = REASONS.dig(reason.to_s, 1)) && _(sentence),
       more.to_s.strip.presence].compact.join("\n\n")
    end

    def scottish_opening(request)
      PlainTextTranslation._(
        "I am writing to require a review of {{authority}}'s handling of " \
        "my request \"{{title}}\", sent on {{date}}.",
        authority: request.public_body.name,
        title: request.title,
        date: long(sent_on(request))
      )
    end

    def scottish_problem(reason, more)
      unless REASONS.key?(reason.to_s)
        return _('Choose what’s wrong with their answer.')
      end

      _('Say what’s wrong with their answer.') if
        reason.to_s == 'other' && more.to_s.strip.empty?
    end

    def frame(request, incoming, review)
      template =
        if review
          OutgoingMessage::Template::InternalReview.new
        elsif incoming&.followup_to_sender?
          OutgoingMessage::Template::IncomingMessageFollowup.new
        else
          OutgoingMessage::Template::InitialRequest.new
        end
      [
        template.salutation(
          public_body_name: OutgoingMailer.name_for_followup(
            request,
            review ? nil : incoming
          )
        ),
        template.signoff
      ]
    end

    def join(middle, request, incoming, review, user_name)
      greeting, signoff = frame(request, incoming, review)
      RequestLetter.text(greeting, middle, signoff, user_name)
    end

    def scottish?(request)
      Deadlines.scottish?(Deadlines.regime(request))
    end
  end
end
