module RequestJourney
  # Check and send's one check, from the requester's own letter: general
  # lessons from FOI letters, never an authority's record. At most one shows;
  # "all emails" first.
  module Checks
    Check = Struct.new(:line, :note, :link, keyword_init: true)

    # rubocop:disable Layout/LineLength
    ALL_EMAILS = /\b(all|any|every|copies of)\s+(\w+\s+){0,3}(correspondence|communications?|e-?mails?|messages|
                  text\smessages|whatsapps?|memos?|memoranda|briefings?|minutes)\b/ix
    ABOUT_YOU = /(my|our)\s(own\s)?(personal\s(data|information|details)|subject\saccess)|
                 (information|data|records?|files?|documents?)\s(that\s)?(you\shold\s|held\s|you\shave\s)?
                   (about|on|relating\sto|concerning|regarding)\s(me|myself)\b|
                 cop(y|ies)\sof\smy\s(file|records?|data|personal|notes)|
                 \bmy\s(own\s)?(case|file|account|claim|application|complaint|appeal|tenancy|benefits?|medical|health|
                   employment|dismissal|grievance|disciplinary|son|daughter|child|children|father|mother|husband|wife|
                   partner|property|house|home|vehicle|car|planning\sapplication|pcn|penalty|parking\sticket|arrest|
                   conviction|caution|treatment|employer|landlord|neighbou?rs?|
                   (medical|health|personal|police|social\scare|care|school)\srecords?)\b|
                 \bi\s(was|am|have\sbeen)\s(arrested|stopped|dismissed|a\spatient|a\stenant|sacked|assaulted|charged|interviewed)/ix
    # rubocop:enable Layout/LineLength
    SUBJECT_ACCESS = 'https://ico.org.uk/for-the-public/getting-copies-of-your-information-subject-access-request/'.freeze

    module_function

    def for(text)
      if ALL_EMAILS.match?(text.to_s)
        Check.new(
          line: _('Name the records'),
          note: _('Limit it to the people, dates and records you need.')
        )
      elsif ABOUT_YOU.match?(text.to_s)
        Check.new(
          line: _('About you?'),
          note: _('Ask for your own records with a subject access request.'),
          link: [_('Ask for own records'), SUBJECT_ACCESS]
        )
      end
    end
  end
end
