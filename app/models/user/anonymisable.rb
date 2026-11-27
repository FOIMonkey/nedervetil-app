# Mixed into User to add user-scoped CensorRules that redact the account's
# current and previous names across its requests.
module User::Anonymisable
  extend ActiveSupport::Concern

  def anonymise!
    if info_requests.none? && Disclosures::Document.where(owner_id: id).none?
      return
    end

    current_name = read_attribute(:name)
    [current_name, *previous_names].each do |name|
      censor_rules.create!(text: NamePattern.new(name).to_censor_rule_text,
                           replacement: _('[Name Removed]'),
                           regexp: true,
                           case_sensitive: false,
                           last_edit_editor: 'User#anonymise!',
                           last_edit_comment: 'User#anonymise!')
    end
  end
end
