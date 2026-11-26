module AlaveteliGetText
  # Removes fuzzy markers and clears their msgstr translations in .po files for
  # the gettext rake tasks.
  class FuzzyCleaner
    def clean_po(input)
      lines = input.split("\n")

      lines.each_with_index do |line, index|
        next unless /^msgid "(.*)"/.match?(line)
        next unless /^#, fuzzy/.match?(lines[index - 1])

        # one line msgstr
        if /^msgstr "(.+)"/.match?(lines[index + 1])
          lines[index + 1] = "msgstr \"\""
          lines.delete_at(index - 1)
        end
        # multiline msgstr
        if /^msgstr ""/.match?(lines[index + 1])
          lines.delete_at(index + 2) while /^".+"/.match?(lines[index + 2])
          lines.delete_at(index - 1)
        end
        # plural msgstr
        if /^msgid_plural "(.*)"/.match?(lines[index + 1])
          offset = 0
          while /^msgstr\[#{offset}\] "(.*)"/.
                match?(lines[index + 2 + offset])
            lines[index + 2 + offset] = "msgstr[#{offset}] \"\""
            offset += 1
          end
          lines.delete_at(index - 1)
        end
      end

      lines.join("\n") << "\n"
    end
  end
end
