require 'spec_helper'

RSpec.describe 'Request classifications', type: :request do
  describe 'POST create' do
    describe 'when the request is internal' do
      let(:info_request) { FactoryBot.create(:info_request) }

      def classifications_path_for(info_request)
        classifications_path(url_title: info_request.url_title)
      end

      def post_status(status, message: nil)
        classification = { described_state: status }
        classification[:message] = message if message

        post classifications_path_for(info_request), params: {
          classification: classification,
          last_info_request_event_id: info_request.
            last_event_id_needing_description
        }
      end

      it 'answers not found if not logged in' do
        post_status('rejected')
        expect(response).to have_http_status(:not_found)
        expect(info_request.reload.described_state).to eq('waiting_response')
      end

      context 'when the requester is suspended', local_requests: false do
        before do
          info_request.user.update!(ban_text: 'Spam')
          sign_in! info_request.user
        end

        it 'refuses a status with a 403 page' do
          post_status('rejected')
          expect(response).to have_http_status(:forbidden)
          expect(response.body).to include('id="error-page"')
          expect(info_request.reload.described_state).to eq('waiting_response')
        end

        it 'refuses a choice about a reply with a 403 page' do
          post attention_choice_path(info_request.url_title),
               params: { incoming_attention_choice: 'routine',
                         incoming_message_id: 1 }
          expect(response).to have_http_status(:forbidden)
          expect(response.body).to include('id="error-page"')
        end
      end

      it 'should not classify the request if logged in as the wrong user' do
        other_user = FactoryBot.create(:user)
        sign_in other_user
        expect_signed_in_as(other_user)
        post_status('rejected')
        expect(response).to have_http_status(:not_found)
        expect(info_request.reload.described_state).to eq('waiting_response')
      end

      describe 'when the request is old and unclassified' do
        let(:info_request) { FactoryBot.create(:old_unclassified_request) }

        describe 'when the user is not logged in' do
          it 'answers not found' do
            post_status('rejected')
            expect(response).to have_http_status(:not_found)
          end
        end

        describe 'when the user is logged in as a different user' do
          # Only an admin can see someone else's request.
          let(:other_user) { FactoryBot.create(:admin_user) }

          before do
            sign_in other_user
          end

          it 'should classify the request' do
            post_status('rejected')
            expect(info_request.reload.described_state).to eq('rejected')
          end

          it 'should log a status update event' do
            expected_params = { user: { gid: other_user.to_global_id.to_s },
                                old_described_state: 'waiting_response',
                                described_state: 'rejected' }
            post_status('rejected')
            last_event = info_request.reload.info_request_events.last
            expect(last_event.params).to eq expected_params
          end

          it 'should redirect to the request page' do
            post_status('rejected')
            expect(response).to redirect_to(
              show_request_path(info_request.url_title)
            )
          end

          it 'should show a message thanking the user for a good deed' do
            post_status('rejected')
            expect(flash[:notice]).to eq('Thank you for updating this request!')
          end

          context 'when the new status is "requires_admin"' do
            it 'should send a mail to admins saying that the response ' \
               'requires admin and one to the requester noting the status ' \
               'change' do
              post_status('requires_admin', message: 'a message')
              deliveries = ActionMailer::Base.deliveries
              expect(deliveries.size).to eq(1)
              mail = deliveries[0]
              expect(mail.subject).to match(/FOI response requires admin/)
              expect(mail.to).to match([AlaveteliConfiguration.contact_email])
            end

            context "if the params don't include a message" do
              it 'redirects to the message url' do
                post_status('requires_admin')
                expect(response).to redirect_to(
                  message_classification_url(
                    url_title: info_request.url_title,
                    described_state: 'requires_admin'
                  )
                )
              end
            end
          end
        end
      end

      describe 'when logged in as an admin user who is not the actual ' \
               'requester' do
        let(:admin_user) { FactoryBot.create(:admin_user) }
        let(:info_request) { FactoryBot.create(:info_request) }

        before do
          sign_in admin_user
        end

        it 'should update the status of the request' do
          post_status('rejected')
          expect(info_request.reload.described_state).to eq('rejected')
        end

        it 'should log a status update event' do
          expected_params = { user: { gid: admin_user.to_global_id.to_s },
                              old_described_state: 'waiting_response',
                              described_state: 'rejected' }
          post_status('rejected')
          last_event = info_request.reload.info_request_events.last
          expect(last_event.params).to eq expected_params
        end

        it 'should record a classification' do
          post_status('rejected')
          last_event = info_request.reload.info_request_events.last
          classification = RequestClassification.order(created_at: :desc).last
          expect(classification.user_id).to eq(admin_user.id)
          expect(classification.info_request_event).to eq(last_event)
        end

        it 'should redirect to the request page' do
          post_status('rejected')
          expect(response).to redirect_to(
            show_request_path(info_request.url_title)
          )
        end

        it 'should show a message thanking the user for a good deed' do
          post_status('rejected')
          expect(flash[:notice]).to eq('Thank you for updating this request!')
        end
      end

      describe 'when logged in as an admin user who is also the actual ' \
               'requester' do
        let(:admin_user) { FactoryBot.create(:admin_user) }
        let(:info_request) do
          FactoryBot.create(:info_request, user: admin_user)
        end

        before do
          sign_in admin_user
        end

        it 'should update the status of the request' do
          post_status('rejected')
          expect(info_request.reload.described_state).to eq('rejected')
        end

        it 'should log a status update event' do
          expected_params = { user: { gid: admin_user.to_global_id.to_s },
                              old_described_state: 'waiting_response',
                              described_state: 'rejected' }
          post_status('rejected')
          last_event = info_request.reload.info_request_events.last
          expect(last_event.params).to eq expected_params
        end

        it 'should show advice for the new state' do
          post_status('rejected')
          expect(flash[:notice][:partial]).to eq(
            'request/describe_notices/rejected'
          )
        end

        it 'should redirect to the unhappy page' do
          post_status('rejected')
          expect(response).to redirect_to(
            help_unhappy_path(info_request.url_title)
          )
        end
      end

      describe 'when logged in as the requestor' do
        let(:info_request) do
          FactoryBot.create(:info_request, awaiting_description: true)
        end

        before do
          sign_in info_request.user
        end

        it 'should let you know when you forget to select a status' do
          post classifications_path_for(info_request), params: {
            last_info_request_event_id: info_request.
              last_event_id_needing_description
          }
          expect(response).to redirect_to(
            show_request_url(info_request.url_title)
          )
          expect(flash[:error]).to eq(
            'Please choose whether or not you got some of the information ' \
            'that you wanted.'
          )
        end

        it 'should not change the status if the request has changed while ' \
           'viewing it' do
          post classifications_path_for(info_request), params: {
            classification: { described_state: 'rejected' },
            last_info_request_event_id: 1
          }
          expect(response).to redirect_to(
            show_request_url(info_request.url_title)
          )
          expect(flash[:error]).to match(
            /The request has been updated since you originally loaded this page/
          )
          expect(info_request.reload.described_state).not_to eq('rejected')
        end

        it 'should successfully classify response' do
          post_status('rejected')
          expect(response).to redirect_to(
            help_unhappy_path(info_request.url_title)
          )
          info_request.reload
          expect(info_request.awaiting_description).to eq(false)
          expect(info_request.described_state).to eq('rejected')
          expect(info_request.info_request_events.last.event_type).to eq(
            'status_update'
          )
          expect(info_request.info_request_events.last.calculated_state).to eq(
            'rejected'
          )
        end

        it 'should log a status update event' do
          expected_params = {
            user: { gid: info_request.user.to_global_id.to_s },
            old_described_state: 'waiting_response',
            described_state: 'rejected'
          }
          post_status('rejected')
          last_event = info_request.reload.info_request_events.last
          expect(last_event.params).to eq expected_params
        end

        it 'should go to the page asking for more information when ' \
           'classified as requires_admin' do
          post_status('requires_admin')
          expect(response).to redirect_to(
            message_classification_url(url_title: info_request.url_title,
                                       described_state: 'requires_admin')
          )

          info_request.reload
          expect(info_request.described_state).not_to eq('requires_admin')
          expect(ActionMailer::Base.deliveries).to be_empty
        end

        context 'message is included when classifying as requires_admin' do
          it 'should send an email including the message' do
            post_status('requires_admin', message: 'Something weird happened')
            deliveries = ActionMailer::Base.deliveries
            expect(deliveries.size).to eq(1)
            mail = deliveries[0]
            expect(mail.body).to match(/as needing admin/)
            expect(mail.body).to match(/Something weird happened/)
          end
        end

        it 'should show advice for the new state' do
          post_status('rejected')
          expect(flash[:notice][:partial]).to eq(
            'request/describe_notices/rejected'
          )
        end

        it 'should redirect to the unhappy page' do
          post_status('rejected')
          expect(response).to redirect_to(
            help_unhappy_path(info_request.url_title)
          )
        end

        it 'knows about extended states' do
          custom_states = Rails.root.join('spec', 'models', 'customstates')
          InfoRequest.send(:require, custom_states)
          InfoRequest.include InfoRequestCustomStates
          InfoRequest.class_eval('@@custom_states_loaded = true')
          ClassificationsController.send(:require, custom_states)
          ClassificationsController.include RequestControllerCustomStates
          ClassificationsController.class_eval('@@custom_states_loaded = true')
          # A request made today is well within its extended deadline.
          post_status('deadline_extended')
          expect(flash[:notice]).to eq(
            'Authority has requested extension of the deadline.'
          )
        end
      end

      describe 'after a successful status update by the request owner' do
        let(:info_request) { FactoryBot.create(:info_request) }

        before do
          sign_in info_request.user
        end

        context 'when status is updated to "waiting_response"' do
          it 'should redirect to the "request url"' do
            post_status('waiting_response')
            expect(response).to redirect_to(
              show_request_path(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('waiting_response')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/waiting_response'
            )
          end
        end

        context 'when status is updated to "waiting_response" and overdue' do
          let(:info_request) { FactoryBot.create(:overdue_request) }

          it 'should redirect to the "request url"' do
            post_status('waiting_response')
            expect(response).to redirect_to(
              show_request_path(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('waiting_response')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/waiting_response_overdue'
            )
          end
        end

        context 'when status is updated to "waiting_response" and very ' \
                'overdue' do
          let(:info_request) { FactoryBot.create(:very_overdue_request) }

          it 'should redirect to the "request url"' do
            post_status('waiting_response')
            expect(response).to redirect_to(
              help_unhappy_path(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('waiting_response')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/waiting_response_very_overdue'
            )
          end
        end

        context 'when status is updated to "not held"' do
          it 'should redirect to the unhappy page, as for "rejected"' do
            post_status('not_held')
            expect(response).to redirect_to(
              help_unhappy_path(info_request.url_title)
            )
          end

          it 'should show the message for "rejected"' do
            post_status('not_held')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/rejected'
            )
          end
        end

        context 'when status is updated to "successful"' do
          it 'should redirect to the "request url"' do
            post_status('successful')
            expect(response).to redirect_to(
              show_request_path(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('successful')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/successful'
            )
          end
        end

        context 'when status is updated to "waiting clarification"' do
          context 'when there is a last response' do
            let(:info_request) do
              FactoryBot.create(:info_request_with_incoming)
            end

            it 'should redirect to the "response url"' do
              post_status('waiting_clarification')
              expect(response).to redirect_to(
                new_request_incoming_followup_path(
                  info_request.url_title,
                  incoming_message_id: info_request.last_public_response.id
                )
              )
            end

            it 'should show a message' do
              post_status('waiting_clarification')
              expect(flash[:notice][:partial]).to eq(
                'request/describe_notices/waiting_clarification'
              )
            end
          end

          context 'when there are no events needing description' do
            it 'should redirect to the "followup no incoming url"' do
              post_status('waiting_clarification')
              expect(response).to redirect_to(
                new_request_followup_path(
                  info_request.url_title,
                  incoming_message_id: nil
                )
              )
            end

            it 'should show a message' do
              post_status('waiting_clarification')
              expect(flash[:notice][:partial]).to eq(
                'request/describe_notices/waiting_clarification'
              )
            end
          end
        end

        context 'when status is updated to "rejected"' do
          it 'should redirect to the "unhappy url"' do
            post_status('rejected')
            expect(response).to redirect_to(
              help_unhappy_path(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('rejected')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/rejected'
            )
          end
        end

        context 'when status is updated to "partially successful"' do
          it 'should redirect to the "unhappy url"' do
            post_status('partially_successful')
            expect(response).to redirect_to(
              help_unhappy_path(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('partially_successful')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/partially_successful'
            )
          end
        end

        context 'when status is updated to "gone postal"' do
          let(:info_request) { FactoryBot.create(:info_request_with_incoming) }

          it 'should redirect to the "respond to last" url' do
            post_status('gone_postal')
            expect(response).to redirect_to(
              new_request_incoming_followup_path(
                info_request.url_title,
                incoming_message_id: info_request.last_public_response.id,
                gone_postal: 1
              )
            )
          end

          it 'should not show a message' do
            post_status('gone_postal')
            expect(flash[:notice]).to be_nil
          end
        end

        context 'when status updated to "internal review"' do
          it 'should redirect to the "request url"' do
            post_status('internal_review')
            expect(response).to redirect_to(
              show_request_path(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('internal_review')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/internal_review'
            )
          end
        end

        context 'when status is updated to "requires admin"' do
          it 'should redirect to the "request url"' do
            post_status('requires_admin', message: 'A message')
            expect(response).to redirect_to(
              show_request_url(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('requires_admin', message: 'A message')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/requires_admin'
            )
          end

          context "if the params don't include a message" do
            it 'redirects to the classification message action' do
              post_status('requires_admin')
              expect(response).to redirect_to(
                message_classification_url(
                  url_title: info_request.url_title,
                  described_state: 'requires_admin'
                )
              )
            end

            it 'should not show a message' do
              post_status('requires_admin')
              expect(flash[:notice]).to be_nil
            end
          end
        end

        context 'when status is updated to "error message"' do
          it 'should redirect to the "request url"' do
            post_status('error_message', message: 'A message')
            expect(response).to redirect_to(
              show_request_url(info_request.url_title)
            )
          end

          it 'should show a message' do
            post_status('error_message', message: 'A message')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/error_message'
            )
          end

          context "if the params don't include a message" do
            it 'redirects to the classification message action' do
              post_status('error_message')
              expect(response).to redirect_to(
                message_classification_url(
                  url_title: info_request.url_title,
                  described_state: 'error_message'
                )
              )
            end

            it 'should not show a message' do
              post_status('error_message')
              expect(flash[:notice]).to be_nil
            end
          end
        end

        context 'when status is updated to "user_withdrawn"' do
          let(:info_request) { FactoryBot.create(:info_request_with_incoming) }

          it 'should redirect to the "respond to last" url' do
            post_status('user_withdrawn')
            expect(response).to redirect_to(
              new_request_incoming_followup_path(
                info_request.url_title,
                incoming_message_id: info_request.last_public_response.id
              )
            )
          end

          it 'should show a message' do
            post_status('user_withdrawn')
            expect(flash[:notice][:partial]).to eq(
              'request/describe_notices/user_withdrawn'
            )
          end
        end
      end
    end
  end

  describe 'GET message' do
    include_examples 'adding classification message action'

    let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
    let(:message_path) do
      message_classification_path(url_title: info_request.url_title,
                                  described_state: 'error_message')
    end

    it 'sends the last event needing description with the message' do
      expect(page.at_css("input[name='last_info_request_event_id']")['value']).
        to eq(info_request.last_event_id_needing_description.to_s)
    end
  end
end
