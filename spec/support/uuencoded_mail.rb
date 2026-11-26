module UuencodedMail
  # parts: [content_type, block_count]; each block has distinct content.
  def uuencoded_mail(*parts)
    blocks = 0
    bodies = parts.map do |content_type, count|
      text = Array.new(count) do
        blocks += 1
        "begin 644 file-#{blocks}.txt\n" \
          "#{["contents of file #{blocks}"].pack('u')}`\nend\n"
      end.join("\n")
      "--frontier\nContent-Type: #{content_type}\n\nSome text.\n\n#{text}"
    end
    mail = <<~MAIL
      From: Information Rights <foi@synthetic-authority.test>
      To: request@example.com
      Subject: Uuencoded attachments
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="frontier"

      #{bodies.join("\n")}
      --frontier--
    MAIL
    mail.gsub("\n", "\r\n")
  end
end
