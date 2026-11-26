# Mixed into User to provide User.unused, selecting inactive accounts with no
# requests, batches, classifications, change requests, admin role, recent
# sign-ins or owned disclosure documents.
module User::Unused
  extend ActiveSupport::Concern

  class_methods do
    # return an array of unused users i.e. users without any user generated
    # content, without granted an user role or recent sign ins
    def unused
      # don't return admins
      roles = Role.arel_table
      user_roles = Arel::Table.new(:users_roles)
      user_roles_exists = user_roles.project(1).
        join(roles).on(user_roles[:role_id].eq(roles[:id])).
        where(user_roles[:user_id].eq(User.arel_table[:id])).
        where(roles[:name].eq('admin')).
        exists

      # don't return users who have signed in recently
      sign_ins = User::SignIn.arel_table
      sign_ins_exists = sign_ins.project(1).
        where(sign_ins[:user_id].eq(User.arel_table[:id])).
        exists

      # keep document owners so documents survive request deletion
      documents = Disclosures::Document.arel_table
      documents_exists = documents.project(1).
        where(documents[:owner_id].eq(User.arel_table[:id])).
        exists

      User.
        where.not(email: internal_admin_user.email).
        where(info_requests_count: 0).
        where(info_request_batches_count: 0).
        where(request_classifications_count: 0).
        where(status_update_count: 0).
        where(public_body_change_requests_count: 0).
        where.not(user_roles_exists).
        where.not(sign_ins_exists).
        where.not(documents_exists)
    end
  end
end
