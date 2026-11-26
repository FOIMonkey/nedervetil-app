# -*- encoding : utf-8 -*-
# validate.rb:
# mySociety library of validation functions, such as valid email address.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: validate.rb,v 1.8 2009-10-19 23:52:40 francis Exp $

module MySociety
    module Validate

        # This method should become part of ruby as of 1.8.7
        def self.each_char(s)
            if block_given?
                s.scan(/./mu) do |x|
                    yield x
                end
            else
                s.scan(/./mu)
            end
        end

        def self.contains_uppercase(s)
            /[[:upper:]]/.match s
        end

        def self.contains_lowercase(s)
            /[[:lower:]]/.match s
        end

        # Stop someone writing all in capitals, or all lower case letters.
        def self.uses_mixed_capitals(s, allow_shorter_than = 20)
            # strip any URLs, as they tend to be all lower case and shouldn't count towards penalty
            s = s.gsub(/(https?):\/\/([^\s<>{}()]+[^\s.,<>{}()])/i, "")
            s = s.gsub(/(\s)www\.([a-z0-9\-]+)((?:\.[a-z0-9\-\~]+)+)((?:\/[^ <>{}()\n\r]*[^., <>{}()\n\r])?)/i, "")

            # count Roman alphabet lower and upper case letters
            capitals = 0
            lowercase = 0
            Validate.each_char(s) do |c|
                capitals = capitals + 1 if Validate.contains_uppercase(c)
                lowercase = lowercase + 1 if Validate.contains_lowercase(c)
            end

            # allow short things (e.g. short titles might be validly all caps)
            # (also avoids division by zero)
            return true if (capitals + lowercase < allow_shorter_than)

            # what proportion of roman A-Z letters are capitals?
            percent_capitals = capitals.to_f / (capitals + lowercase).to_f * 100
            #STDOUT.puts("percent_capitals " + percent_capitals.to_s)

            # anything more than 75% caps, or less than 0.5% capitals
            # XXX should check these against database of old FOI requests etc.
            if percent_capitals > 75.0 || percent_capitals < 0.5
                return false
            end

            return true
        end

        def self.email_match_regexp

            # This is derived from the grammar in RFC2822.
            # mailbox = local-part "@" domain
            # local-part = dot-string | quoted-string
            # dot-string = atom ("." atom)*
            # atom = atext+
            # atext = any character other than space, specials or controls
            # quoted-string = '"' (qtext|quoted-pair)* '"'
            # qtext = any character other than '"', '\', or CR
            # quoted-pair = "\" any character
            # domain = sub-domain ("." sub-domain)* | address-literal
            # sub-domain = [A-Za-z0-9][A-Za-z0-9-]*
            # XXX ignore address-literal because nobody uses those...
            # XXX Update this for http://tools.ietf.org/html/rfc6530
            # N.B. intended for validating email addresses in their canonical form,
            # so does not allow folding whitespace

            specials = '()<>@,;:\\\\".\\[\\]'
            controls = '\\000-\\037\\177'
            # To add MacRuby support, see https://github.com/nex3/sass/pull/432
            highbit = '\\u{80}-\\u{D7FF}\\u{E000}-\\u{FFFD}\\u{10000}-\\u{10FFFF}'
            atext = "[^#{specials} #{controls}#{highbit}]"
            atom = "#{atext}+"
            dot_string = "#{atom}(\\.#{atom})*"
            qtext = "[^\"\\\\\\r\\n#{highbit}]"
            quoted_pair = '\\.'
            quoted_string = "\"(#{qtext}|#{quoted_pair})*\""
            local_part = "(#{dot_string}|#{quoted_string})"
            sub_domain = '[A-Za-z0-9][A-Za-z0-9-]*'
            domain = "#{sub_domain}(\\.#{sub_domain})*"

            return "#{local_part}@#{domain}"
        end

        def self.is_valid_email(addr)
            is_valid_address_re = Regexp.new("\\A#{Validate.email_match_regexp}\\z")

            return addr =~ is_valid_address_re
        end

        # For finding email addresses in a body of text.
        # XXX Less exact than the one above, but I had problems in Ruby's
        # regexp engine with the one above crashing it.
        #
        # Upstream's pattern, whose last label is two to four letters, is
        # tried first at each place, so everything it finds is still found.
        # Only where it finds nothing may the last label be longer, so that
        # addresses at gov.wales and llyw.cymru are found. The longer label
        # must be all lower case or all capitals, and @ or :// must not follow
        # it. The default masks apply this pattern before the mobile number
        # and sign-in link masks and the censor rules, which never see what
        # it takes: in
        # jane@gov.wales.Mobile: 07700 900123 the word Mobile is what the
        # mobile number mask looks for, a label before @ belongs to the next
        # address, and one before :// begins a link.
        def self.email_find_regexp
            name = '[A-Za-z0-9._%+-]+'
            domain = '[A-Za-z0-9.-]+'
            short = "#{domain}\\.[A-Za-z]{2,4}\\b"
            long = "#{domain}\\.(?:[a-z]{5,}|[A-Z]{5,})\\b(?!@|://)"
            return Regexp.new("(\\b#{name}@(?:#{short}|#{long}))")
        end

        # is_valid_postcode POSTCODE
        # Return true if POSTCODE is in the proper format for a UK postcode. Does not
        # require spaces in the appropriate place.
        def self.is_valid_postcode(postcode)
            return Validate.postcode_match_internal(postcode, "\\A", "\\z")
        end

        # is_valid_partial_postcode POSTCODE
        # Returns true if POSTCODE is in the proper format for the first part of a UK
        # postcode. Expects a stripped string.
        def self.is_valid_partial_postcode(postcode)

            # Our test postcode
            if (postcode.match(/\Azz9\z/i))
                return true
            end

            fst = 'ABCDEFGHIJKLMNOPRSTUWYZ'
            sec = 'ABCDEFGHJKLMNOPQRSTUVWXY'
            thd = 'ABCDEFGHJKSTUW'
            fth = 'ABEHMNPRVWXY'
            num0 = '123456789' # Technically allowed in spec, but none exist
            num = '0123456789'

            if (postcode.match(/\A[#{fst}][#{num0}]\z/i) ||
                postcode.match(/\A[#{fst}][#{num0}][#{num}]\z/i) ||
                postcode.match(/\A[#{fst}][#{sec}][#{num}]\z/i) ||
                postcode.match(/\A[#{fst}][#{sec}][#{num0}][#{num}]\z/i) ||
                postcode.match(/\A[#{fst}][#{num0}][#{thd}]\z/i) ||
                postcode.match(/\A[#{fst}][#{sec}][#{num0}][#{fth}]\z/i
                ))
                return true
            else
                return false
            end
        end

        def self.contains_postcode?(postcode)
            return Validate.postcode_match_internal(postcode, "\\b", "\\b")
        end

        def self.postcode_match_internal(postcode, pre, post)
            # Our test postcode
            if (postcode.match(/#{pre}zz9\s*9z[zy]#{post}/i))
                return true
            end

            # See http://www.govtalk.gov.uk/gdsc/html/noframes/PostCode-2-1-Release.htm
            inn  = 'ABDEFGHJLNPQRSTUWXYZ'
            fst = 'ABCDEFGHIJKLMNOPRSTUWYZ'
            sec = 'ABCDEFGHJKLMNOPQRSTUVWXY'
            thd = 'ABCDEFGHJKSTUW'
            fth = 'ABEHMNPRVWXY'
            num0 = '123456789' # Technically allowed in spec, but none exist
            num = '0123456789'
            nom = '0123456789'
            gap = '\s\.'

            if (postcode.match(/#{pre}[#{fst}][#{num0}][#{gap}]*[#{nom}][#{inn}][#{inn}]#{post}/i) ||
                postcode.match(/#{pre}[#{fst}][#{num0}][#{num}][#{gap}]*[#{nom}][#{inn}][#{inn}]#{post}/i) ||
                postcode.match(/#{pre}[#{fst}][#{sec}][#{num}][#{gap}]*[#{nom}][#{inn}][#{inn}]#{post}/i) ||
                postcode.match(/#{pre}[#{fst}][#{sec}][#{num0}][#{num}][#{gap}]*[#{nom}][#{inn}][#{inn}]#{post}/i) ||
                postcode.match(/#{pre}[#{fst}][#{num0}][#{thd}][#{gap}]*[#{nom}][#{inn}][#{inn}]#{post}/i) ||
                postcode.match(/#{pre}[#{fst}][#{sec}][#{num0}][#{fth}][#{gap}]*[#{nom}][#{inn}][#{inn}]#{post}/i))
                return true
            else
                return false
            end
        end

    end
end

