require 'spec_helper'

RSpec.describe OutgoingMailer, "when working out follow up subjects" do
  it "should prefix the title with 'Freedom of Information request -' for initial requests" do
    ir = info_requests(:fancy_dog_request)

    expect(ir.email_subject_request(html: false)).to eq(
      "Freedom of Information request - Why do you have & such a fancy dog?"
    )
  end

  it "should use 'Re:' and initial request subject for followups which aren't replies to particular messages" do
    ir = info_requests(:fancy_dog_request)
    om = outgoing_messages(:useless_outgoing_message)

    expect(OutgoingMailer.subject_for_followup(ir, om, html: false)).
      to eq("Re: Freedom of Information request - " \
            "Why do you have & such a fancy dog?")
  end

  it "should prefix with Re: the subject of the message being replied to" do
    ir = info_requests(:fancy_dog_request)
    im = ir.incoming_messages[0]
    om = outgoing_messages(:useless_outgoing_message)
    om.incoming_message_followup = im

    expect(OutgoingMailer.subject_for_followup(ir, om, html: false)).
      to eq("Re: Geraldine FOI Code AZXB421")
  end

  it "should not add Re: prefix if there already is such a prefix" do
    ir = info_requests(:fancy_dog_request)
    im = ir.incoming_messages[0]
    om = outgoing_messages(:useless_outgoing_message)
    om.incoming_message_followup = im

    im.raw_email.data = im.raw_email.data.sub(
      "Subject: Geraldine FOI Code AZXB421",
      "Subject: Re: Geraldine FOI Code AZXB421"
    )
    expect(OutgoingMailer.subject_for_followup(ir, om, html: false)).
      to eq("Re: Geraldine FOI Code AZXB421")
  end

  it "should not add Re: prefix if there already is a lower case re: prefix" do
    ir = info_requests(:fancy_dog_request)
    im = ir.incoming_messages[0]
    om = outgoing_messages(:useless_outgoing_message)
    om.incoming_message_followup = im

    im.raw_email.data = im.raw_email.data.sub(
      "Subject: Geraldine FOI Code AZXB421",
      "Subject: re: Geraldine FOI Code AZXB421"
    )
    im.parse_raw_email!

    expect(OutgoingMailer.subject_for_followup(ir, om, html: false)).
      to eq("re: Geraldine FOI Code AZXB421")
  end

  it "should use 'Re:' and initial request subject when replying to failed delivery notifications" do
    ir = info_requests(:fancy_dog_request)
    im = ir.incoming_messages[0]
    om = outgoing_messages(:useless_outgoing_message)
    om.incoming_message_followup = im

    im.raw_email.data = im.raw_email.data.sub(
      "foiperson@localhost", "postmaster@localhost"
    )
    im.raw_email.data = im.raw_email.data.sub(
      "Subject: Geraldine FOI Code AZXB421", "Subject: Delivery Failed"
    )
    im.parse_raw_email!

    expect(OutgoingMailer.subject_for_followup(ir, om, html: false)).
      to eq("Re: Freedom of Information request - " \
            "Why do you have & such a fancy dog?")
  end

  context "dealing with an internal review" do
    it "prefixes the subject of the message with 'Internal review of " \
          "Freedom of Information request'" do
      request = FactoryBot.create(:info_request_with_internal_review_request,
                                  title: "Test")
      expect(OutgoingMailer.subject_for_followup(
               request,
        request.outgoing_messages.last
             )).
          to eq("Internal review of Freedom of Information request - Test")
    end

    it "does not add HTMLEntities to the subject of the message" do
      request = FactoryBot.create(:info_request_with_internal_review_request,
                                  title: "Apostrophe's Test")
      expect(OutgoingMailer.subject_for_followup(
               request,
        request.outgoing_messages.last
             )).
          to eq("Internal review of Freedom of Information request - " \
                "Apostrophe's Test")
    end
  end
end
