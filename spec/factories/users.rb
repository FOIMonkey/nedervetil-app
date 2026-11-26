# == Schema Information
#
# Table name: users
#
#  id                                :integer          not null, primary key
#  email                             :string           not null
#  name                              :string           not null
#  hashed_password                   :string           default(""), not null
#  salt                              :string
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  email_confirmed                   :boolean          default(FALSE), not null
#  url_name                          :text             not null
#  last_daily_track_email            :datetime
#  ban_text                          :text             default(""), not null
#  locale                            :string
#  email_bounced_at                  :datetime
#  email_bounce_message              :text             default(""), not null
#  trusted                           :boolean          default(FALSE), not null
#  receive_email_alerts              :boolean          default(TRUE), not null
#  otp_enabled                       :boolean          default(FALSE), not null
#  otp_secret_key                    :string
#  otp_counter                       :integer
#  confirmed_not_spam                :boolean          default(FALSE), not null
#  info_requests_count               :integer          default(0), not null
#  request_classifications_count     :integer          default(0), not null
#  public_body_change_requests_count :integer          default(0), not null
#  info_request_batches_count        :integer          default(0), not null
#  daily_summary_hour                :integer
#  daily_summary_minute              :integer
#  closed_at                         :datetime
#  login_token                       :string
#  status_update_count               :integer          default(0), not null
#  last_sign_in_at                   :datetime
#  otp_last_used_at                  :integer
#  otp_enabled_at                    :datetime
#  otp_backup_codes_generated_at     :datetime
#  otp_backup_codes                  :text
#  encrypted_password                :string           default(""), not null
#  reset_password_token              :string
#  reset_password_sent_at            :datetime
#  confirmation_token                :string
#  confirmation_sent_at              :datetime
#  confirmed_at                      :datetime
#  unconfirmed_email                 :string
#  otp_secret                        :text
#  consumed_timestep                 :bigint
#  otp_required_for_login            :boolean          default(FALSE), not null
#  devise_otp_backup_codes           :string           default([]), not null, is an Array
#  authentication_version            :string           default(""), not null
#  credential_reset_required         :boolean          default(FALSE), not null
#

FactoryBot.define do
  factory :user do
    # Letters, not numbers: the document name check treats a 4+ char last word
    # as a surname, so "Example User 2026" would collide with years in titles.
    sequence(:name, 'A') { |n| "Example User #{n}" }
    sequence(:email) { |n| "person#{n}@example.com" }
    password { 'jonespassword' }
    email_confirmed { true }
    ban_text { '' }
    confirmed_not_spam { true }
    last_daily_track_email { Time.zone.now }

    after(:build) { |user| user.send :set_slug }

    factory :unconfirmed_user do
      email_confirmed { false }
      confirmed_not_spam { false }
    end

    factory :admin_user do
      sequence(:name, 'A') { |n| "Admin User #{n}" }
      admin
    end

    # Alias for a plain user; kept for existing specs that name :pro_user.
    factory :pro_user do
      sequence(:name, 'A') { |n| "Pro User #{n}" }
    end

    trait :admin do
      after(:create) { |user| user.add_role(:admin) }
    end

    trait :enable_totp do
      otp_secret { User.generate_otp_secret }
      otp_required_for_login { true }
    end

    trait :unconfirmed do
      email_confirmed { false }
    end

    trait :banned do
      ban_text { 'Banned' }
    end

    trait :limited do
      confirmed_not_spam { false }
      info_requests_count { 0 }
      status_update_count { 0 }
    end

    trait :unused do
      info_requests_count { 0 }
    end

    trait :closed do
      closed_at { Time.zone.now }
      receive_email_alerts { false }
    end

    trait :internal_admin_user do
      email { AlaveteliConfiguration.contact_email }
    end
  end
end
