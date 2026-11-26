require 'spec_helper'

RSpec.describe "followups/_followup" do
  let(:info_request) { FactoryBot.create(:info_request) }

  before do
    assign :info_request, info_request
    assign :internal_review, false
    # By id, as FollowupsController#new builds it: given the request itself,
    # the unsaved message would join the request's messages and be validated
    # whenever the request is saved.
    assign :outgoing_message,
           OutgoingMessage.new(info_request_id: info_request.id)
    assign :is_owning_user, true
    assign :refusal_advice, RefusalAdvice.default(info_request)
  end

  it "renders the title partial" do
    stub_template 'followups/_form_title.html.erb' => 'FORM TITLE'
    render partial: "followups/followup", locals: { incoming_message: nil }

    expect(rendered).to include('FORM TITLE')
  end

  it 'labels the message field without JavaScript' do
    render partial: 'followups/followup', locals: { incoming_message: nil }

    expect(rendered).to have_css('label[for="outgoing_message_body"]',
                                 text: 'Your message')
    expect(rendered).to have_css('textarea#outgoing_message_body')
  end

  describe 'the request is overdue' do
    context 'the authority is subject to FOI law' do
      it 'tells the user the authority should have responded by law' do
        travel_to(info_request.date_response_required_by + 2.days) do
          render partial: "followups/followup",
                 locals: { incoming_message: nil }
          expect(rendered).
            to have_content 'You can say that, by law, the authority should ' \
                            'normally have responded'
        end
      end
    end

    context 'the authority is not subject to FOI law' do
      it 'tells the user the authority should have responded by law' do
        info_request.public_body.add_tag_if_not_already_present('foi_no')
        travel_to(info_request.date_response_required_by + 2.days) do
          render partial: "followups/followup",
                 locals: { incoming_message: nil }
          expect(rendered).
            to have_no_content 'You can say that, by law, the authority ' \
                                'should normally have responded'
        end
      end
    end
  end

  describe 'the request is very overdue' do
    context 'the authority is subject to FOI law' do
      it 'tells the user the authority should have responded by law' do
        travel_to(info_request.date_very_overdue_after + 2.days) do
          render partial: "followups/followup",
                 locals: { incoming_message: nil }
          expect(rendered).
            to have_content 'You can say that, by law, under all ' \
                            'circumstances, the authority should have ' \
                            'responded by now'
        end
      end
    end

    context 'the authority is not subject to FOI law' do
      it 'tells the user the authority should have responded by law' do
        info_request.public_body.add_tag_if_not_already_present('foi_no')
        travel_to(info_request.date_very_overdue_after + 2.days) do
          render partial: "followups/followup",
                 locals: { incoming_message: nil }
          expect(rendered).
            to have_no_content 'You can say that, by law, under all ' \
                                'circumstances, the authority should have ' \
                                'responded by now'
        end
      end
    end
  end

  describe 'displaying followup contact options' do
    context 'without an incoming message' do
      it 'does not show the "other options" panel' do
        render partial: "followups/followup", locals: { incoming_message: nil }
        expect(rendered).to have_no_content 'You can also write to'
      end
    end

    context 'with an incoming message' do
      let(:incoming) do
        FactoryBot.create(:plain_incoming_message, info_request: info_request)
      end

      it 'shows the "other options" panel if the incoming message is not from the main contact address' do
        render partial: "followups/followup",
               locals: { incoming_message: incoming }
        expect(rendered).to have_content 'You can also write to'
      end

      it 'does not show the "other options" panel if the incoming message is from the main contact address' do
        info_request.
          public_body.
            update_attribute(:request_email, 'bob@example.com')
        render partial: "followups/followup",
               locals: { incoming_message: incoming }
        expect(rendered).to have_no_content 'You can also write to'
      end
    end
  end

  describe 'the request is closed to new responses' do
    before do
      info_request.update_attribute(:allow_new_responses_from, 'nobody')
    end

    it 'does not render the title partial' do
      render partial: 'followups/followup', locals: { incoming_message: nil }
      expect(rendered).to have_no_css('h2', text: 'Send a public follow up')
    end

    it 'does not render the followup form' do
      render partial: 'followups/followup', locals: { incoming_message: nil }
      expect(rendered).to have_no_css 'form#followup_form'
    end

    it 'renders a message to say new responses have been stopped' do
      render partial: 'followups/followup', locals: { incoming_message: nil }

      expect(rendered).
        to have_content 'Follow ups and new responses to this request have ' \
                        'been stopped to prevent spam.'
    end
  end
end
