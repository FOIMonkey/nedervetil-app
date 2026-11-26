# Copyright (c) 2013 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Emails the requester once an InfoRequestBatch finishes sending, listing any
# authorities that could not be contacted.
class InfoRequestBatchMailer < ApplicationMailer
  def batch_sent(info_request_batch, unrequestable, user)
    @info_request_batch = info_request_batch
    @unrequestable = unrequestable
    @url = info_request_batch_url(@info_request_batch)

    mail_user(
      user,
      subject: -> {
        _(
          "Your batch request \"{{title}}\" has been sent",
          title: info_request_batch.title
        )
      }
    )
  end
end
