module IncomingAttention
  # Records a requester's attention choice on a reply (create) and dismisses
  # reviewed routine replies (dismiss).
  class ChoicesController < ::ApplicationController
    include ClassificationRefusal

    # Shares the classifications read-only gate since choices affect status.
    read_only :classifications

    before_action :authorise_info_request

    def create
      choice = params[:incoming_attention_choice]
      return head(:bad_request) unless Choice::VALUES.include?(choice)

      message = Choice.record!(info_request,
                               params[:incoming_message_id],
                               choice,
                               ability: current_ability)
      redirect_to request_path(info_request, anchor: "incoming-#{message.id}")
    end

    def dismiss
      ids = params[:incoming_message_ids]
      unless ids.is_a?(Array) && ids.size.between?(1, 200) &&
             ids.all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) }
        return head(:bad_request)
      end

      ids = ids.map(&:to_i).uniq
      Dismissal.record!(info_request, ids, ability: current_ability)

      # Fixed destinations only; nothing from the request is used as a URL.
      case params[:incoming_attention_return]
      when 'dashboard'
        redirect_to alaveteli_pro_dashboard_path
      when 'routine_updates'
        redirect_to alaveteli_pro_info_requests_path(
          'alaveteli_pro_request_filter[filter]' => 'routine_updates'
        )
      else
        redirect_to request_path(info_request, anchor: "incoming-#{ids.first}")
      end
    rescue Dismissal::Invalid
      head :bad_request
    end

    private

    def info_request
      @info_request ||= InfoRequest.find_by!(url_title: params[:url_title])
    end

    def authorise_info_request
      authorize! :update_request_state, info_request
    end
  end
end
