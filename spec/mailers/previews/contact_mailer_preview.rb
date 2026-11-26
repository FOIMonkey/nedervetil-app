class ContactMailerPreview < ActionMailer::Preview
  def from_admin_message
    ContactMailer.from_admin_message(
      bob.name, bob.email, 'Mail from an admin', 'Bad request'
    )
  end

  private

  def bob
    User.new(id: 1, name: 'Bob', email: 'bob@localhost')
  end
end
