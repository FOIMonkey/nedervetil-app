# CanCanCan authorization policy. Read visibility is split across VisitorRules,
# RequesterRules and AdminRules; action abilities live here. Document and
# attachment rules join in B07.
class Ability
  include CanCan::Ability
  include Ability::VisitorRules
  include Ability::RequesterRules
  include Ability::AdminRules

  attr_reader :user

  def self.guest
    new(nil)
  end

  def initialize(user)
    @user = user

    visitor_rules
    requester_rules if user
    admin_rules if admin?

    request_state_rules
    sending_rules
    request_care_rules
    snippet_and_batch_rules
    account_rules
  end

  private

  def request_state_rules
    can :update_request_state, InfoRequest do |request|
      can_update_request_state?(request)
    end
  end

  def sending_rules
    can :create, InfoRequest if may_act?
    can %i[follow_up send_reminder], InfoRequest do |request|
      may_act? && requester_of?(request) && can?(:read, request)
    end

    return unless may_act? && user.trusted?

    can :create, InfoRequestBatch
  end

  def request_care_rules
    can :adjust_deadlines, InfoRequest do |request|
      may_act? && (requester_of?(request) || admin?) && can?(:read, request)
    end

    can :report, InfoRequest do |request|
      may_act? && can?(:read, request)
    end

    can :delete_request, InfoRequest do |request|
      may_withdraw_or_delete? && requester_of?(request) &&
        can?(:read, request) &&
        !request.holding_pen_request?(read_only: true)
    end
  end

  def snippet_and_batch_rules
    can :manage, OutgoingMessage::Snippet do |_request|
      admin?
    end

    can :download, InfoRequestBatch do |batch_request|
      may_act? && requester_or_admin?(batch_request)
    end

    can :update, InfoRequestBatch do |batch_request|
      may_act? && requester_or_admin?(batch_request)
    end
  end

  def account_rules
    # Kept for themes still checking this instead of request_journey_pro?.
    can :access, :alaveteli_pro if user

    can :login_as, User do |target_user|
      admin? && user != target_user && !target_user.closed?
    end

    can :read, User do |account|
      admin? || (may_act? && account == user)
    end
  end

  # Suspended or closed admins have no admin powers.
  def admin?
    user.present? && user.active_admin?
  end

  def may_act?
    user.present? && user.active?
  end

  # Suspended requesters may still withdraw or delete their own content.
  def may_withdraw_or_delete?
    user.present? && !user.closed?
  end

  # Actual requester only (not an admin), regardless of account state.
  def requester_of?(request)
    user.present? && request.is_actual_owning_user?(user)
  end

  def can_update_request_state?(request)
    may_act? && (requester_of?(request) || admin?)
  end

  def requester_or_admin?(request)
    user == request.user || admin?
  end
end
