module IncomingAttention
  # A yes/no account setting, kept as one row for each account that said yes.
  module AccountSetting
    extend ActiveSupport::Concern

    class_methods do
      def on?(user)
        !!user && exists?(user_id: user.id)
      end

      def set!(user, on)
        return where(user_id: user.id).delete_all unless on

        find_or_create_by!(user_id: user.id)
      rescue ActiveRecord::RecordNotUnique
        true
      end
    end
  end
end
