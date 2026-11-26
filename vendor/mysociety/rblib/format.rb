# -*- encoding : utf-8 -*-
# format.rb:
# mySociety library of formatting functions.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: format.rb,v 1.24 2009-10-04 21:42:07 francis Exp $

# the tests in tests/format.rb should somehow made to run from
# the foi app.
require 'cgi'

module MySociety
    module Format

        # ... or wrapping each line separately.
        def self.wrap_email_body_by_lines(body)
            return Format._wrap_email_internal(body, 67, "     ", "\n")
        end
        # Internal function for above
        def self._wrap_email_internal(body, line_width, indent, paragraph_split)
            body = body.gsub(/\r\n/, "\n") # forms post with \r\n by default
            paras = body.split(paragraph_split)

            result = ''
            for para in paras
                para.gsub!(/\s+/, ' ')
                # the [^\s]{#{line_width+1},} part is to make sure we don't
                # break URLs etc. that are longer than a line, by including
                # anything non whitespace longer than a line whole.
                para.gsub!(/(.{1,#{line_width}}|[^\s]{#{line_width+1},})(\s+|$)/, "#{indent}\\1\n")
                para.strip!
                result = result + indent + para + paragraph_split
            end
            return result
        end

        # Returns text with obvious links made into HTML hrefs.
        # Taken originally from phplib/utility.php and from WordPress, tweaked somewhat.
        # Text passed into here should already have been passed through e.g. CGI.escapeHTML
        def self.make_clickable(text, params = {})
            nofollow = params[:nofollow]
            contract = params[:contract]
            ret = ' ' + text + ' '

            # Special case as we get already HTML encoded < and > at end and start
            # of URLs often, when used to bracket them
            # e.g. http://www.whatdotheyknow.com/request/records_of_tenancy_property#incoming-212
            ret = ret.gsub(/&lt;/, " LTCODE ")
            ret = ret.gsub(/&gt;/, " GTCODE ")

            # Sometimes get angle bracketed URLs with newlines in the middle of them.
            # http://www.whatdotheyknow.com/request/advice_sought_from_information_c#incoming-24711
            ret = ret.gsub(/( LTCODE http[\S\r\n]*? GTCODE )/) { |m| m.gsub(/[\n\r]/, "") }

            # Pull out the urls
            matches = ret.scan(/(https?):\/\/([^\s<>]+[^\s.,<>])/i)
            extras = []
            urls = []

            # In a perfect world, we'd be able to use lookbehind to work out
            # whether the brackets match but Ruby only does immediate lookbehind
            # so...
            #
            # drop the closing bracket off the end until we no longer have more
            # closing than opening brackets or the last char is not a bracket
            matches.each do |match|
                url = match[1]
                extra = ""
                while url.count(')') > url.count('(') && url[-1] == ")"
                    url = url[0..-2]
                    extra = "#{extra})"
                end
                urls << url
                extras << extra
            end

            ret = ret.gsub(/(https?):\/\/([^\s<>]+[^\s.,<>])/i).with_index do | m, i |
               %Q|<a href="#{$1}://#{urls[i]}"| + (nofollow ? ' rel="nofollow"' : "") + ">#{$1}://#{urls[i]}</a>#{extras[i]}"
            end
            ret = ret.gsub(/(\s)www\.([a-z0-9\-]+)((?:\.[a-z0-9\-\~]+)+)((?:\/[^\s<>]*[^\s.,<>])?)/i,
                        '\\1<a href="http://www.\\2\\3\\4"' + (nofollow ? ' rel="nofollow"' : "") + ">www.\\2\\3\\4</a>")
            if contract
                ret = ret.gsub(/(<a href="[^"]*"(?: rel="nofollow")?>)([^<]{43,})<\/a>/) do
                    match = Regexp.last_match
                    label = CGI.unescapeHTML(match[2])
                    label.length >= 43 ? "#{match[1]}#{CGI.escapeHTML(label[0, 40])}...</a>" : match[0]
                end
            end
            ret = ret.gsub(/(\s)([a-z0-9\-_.]+)@([^\s,<]*[^\s.,<])/i, "\\1<a href=\"mailto:\\2@\\3\">\\2@\\3</a>")

            # Put back the codes for < and >
            ret = ret.gsub(" LTCODE ", "&lt;")
            ret = ret.gsub(" GTCODE ", "&gt;")

            ret = ret.strip
            return ret
        end

        # Simplify bracketed URLs like: www.liverpool.gov.uk <http://www.liverpool.gov.uk>
        # (so that the URL appears only once, and so that the escaping of the < > doesn't
        # get &gt; contaminated into the linked URL)
        def self.simplify_angle_bracketed_urls(text)
            ret = ' ' + text + ' '
            ret = ret.gsub(/(www\.[^\s<>]+)\s+<https?:\/\/\1>/i, "\\1")
            ret = ret.strip
            return ret
        end

        # Simplified a name to something usable in a URL
        #
        # Only Latin letters and digits survive (see AsciiText). A name with
        # none, such as one written wholly in Greek or Cyrillic, gives
        # default_name. Requests and authorities add a number to keep a slug
        # unique ("body", "body_2").
        def self.simplify_url_part(text, default_name, max_len = nil)
            text = AsciiText.transliterate(text.downcase).downcase

            text.gsub!(/(\s|-|_)/, "_")
            text.gsub!(/[^a-z0-9_]/, "")
            text.gsub!(/_+/, "_")
            text.gsub!(/^_*/, "")
            text.gsub!(/_*$/, "")

            # If required, trim down to size
            if not max_len.nil?
                if text.size > max_len
                    text = text[0..(max_len-1)]
                end
                # removing trailing _
                text.gsub!(/_*$/, "")
            end
            # Don't allow short (zero length!), or all numeric (clashes with identifiers)
            if text.size < 1 || text.match(/^[0-9]+$/)
                text = default_name # just do "user_1", "user_2" etc.
            end

            text
        end

    end
end

