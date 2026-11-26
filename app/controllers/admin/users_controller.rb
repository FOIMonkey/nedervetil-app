# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Lists, searches and edits User accounts in the admin interface, recording
# permission changes and viewing or clearing email bounce records.
class Admin::UsersController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_user, exclude: []

  include Admin::Searchable
  include Admin::Sortable

  layout 'admin/users'

  before_action :set_admin_user, only: %i[show
                                          edit
                                          update
                                          show_bounce_message
                                          clear_bounce]

  before_action :clear_roles, :clear_features,
                :check_role_authorisation, only: %i[update]

  sortable :name, :created_at, :updated_at,
           relevance: :indexed_search?,
           only: [:index, :active, :banned, :closed]

  sortable default: :updated_at_desc, only: [:show]

  def index
    @title ||= 'Listing users'

    @query = params[:query].try(:strip)

    @roles = params[:roles] || []

    users = user_scope

    users = users.with_any_role(*@roles) unless @roles.empty?

    @admin_users = measure_search(
      sorted(users).preload(:roles, :tags).
        paginate(page: params[:page], per_page: 100)
    )

    render action: :index
  end

  def show
    @info_requests = @admin_user.info_requests
    @info_request_batches = @admin_user.info_request_batches.
                            includes(:public_bodies).to_a

    @prominence_counts = @admin_user.info_requests.reorder(nil).
                         group(:prominence).count
    @request_count = @prominence_counts.values.sum
    @hidden_request_count = @prominence_counts['hidden'].to_i
    @document_count = Disclosures::Document.where(owner_id: @admin_user.id).
                      count
    @sign_ins_count = @admin_user.sign_ins.count
    @sign_ins = @admin_user.sign_ins.includes(:user).limit(50).to_a
    @email_histories = @admin_user.email_histories.
                       order(changed_at: :desc).limit(50).to_a
    @permission_changes = @admin_user.permission_changes.
                          includes(:changed_by).
                          order(created_at: :desc).limit(50).to_a

    @info_requests =
      sorted(@info_requests.includes(:user, public_body: :translations)).
      paginate(page: params[:page], per_page: 100)
  end

  def edit
    # HACK: Override the name param to get the database value.
    # Rails 4.2 calls User#name instead of the `#name_before_type_cast`, so
    # results in the banned user suffix being rendered in to the form field.
    # This value with the suffix then gets persisted on save, breaking URLs.
    @admin_user.name = @admin_user.read_attribute(:name)
  end

  def update
    # A change to the Trusted tick or the admin role is kept with the save.
    # Assigning roles, tags or features writes them straight away, so a
    # failed save rolls them back here: update's own rollback is nested in
    # this transaction and undoes nothing.
    before = User::PermissionChange.current(@admin_user)
    updated = User.transaction do
      raise ActiveRecord::Rollback unless @admin_user.update(user_params)

      User::PermissionChange.record(@admin_user.reload, before, by: @user)
      true
    end

    if updated
      # The role itself, just saved: whether an admin removed their own.
      if @admin_user == @user && !@admin_user.is_admin?
        flash[:notice] = 'User successfully updated - ' \
                         'you are no longer an admin.'
        redirect_to root_path
      else
        flash[:notice] = 'User successfully updated.'
        redirect_to admin_user_url(@admin_user)
      end
    else
      render action: 'edit', status: :unprocessable_content
    end
  end

  def active
    @title = 'Active users'
    @base_scope = User.active
    index
  end

  def banned
    @title = 'Banned users'
    @base_scope = User.banned
    index
  end

  def closed
    @title = 'Closed users'
    @base_scope = User.closed
    index
  end

  def show_bounce_message
  end

  def clear_bounce
    @admin_user.email_bounced_at = nil
    @admin_user.email_bounce_message = ""
    @admin_user.save!
    redirect_to admin_user_url(@admin_user)
  end

  private

  def user_scope
    return base_scope if @query.blank?

    legacy_search? ? legacy_user_scope : indexed_user_scope
  end

  def base_scope
    @base_scope || User
  end

  def legacy_user_scope
    base_scope.legacy_search(@query)
  end

  def indexed_user_scope
    # Admin search uses the admin index. Exact mode keeps fragment searches
    # like partial email addresses working.
    base_scope.search_scope(
      @query,
      admin_mode: true,
      exact_mode: true,
      case_sensitive: false
    )
  end

  def user_params
    if params[:admin_user]
      params.require(:admin_user).permit(:name,
                                         :email,
                                         { role_ids: [] },
                                         { features: [] },
                                         :ban_text,
                                         :trusted,
                                         :confirmed_not_spam,
                                         :tag_string)
    else
      {}
    end
  end

  def clear_roles
    # Clear roles if none checked
    params[:admin_user][:role_ids] ||= []
  end

  def clear_features
    # Clear features if none checked
    params[:admin_user][:features] ||= []
  end

  # Check all changed roles exist, current user can grant and revoke them
  # and requirements are met
  def check_role_authorisation
    all_allowed = changed_role_ids.all? do |role_id|
      role = Role.site_wide.find_by(id: role_id)
      role && @user.can_admin_role?(role.name.to_sym)
    end
    return if all_allowed

    flash[:error] = "Not permitted to change roles"
    render action: 'edit', status: :unprocessable_content and return false
  end

  def changed_role_ids
    params[:admin_user][:role_ids].map!(&:to_i)
    (params[:admin_user][:role_ids] - @admin_user.role_ids) |
      (@admin_user.role_ids - params[:admin_user][:role_ids])
  end

  def set_admin_user
    # Don't use @user as that is any logged in user
    @admin_user = User.find(params[:id])
  end
end
