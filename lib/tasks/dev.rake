namespace :dev do
  desc "Create (or reset) the local testadmin user. EMAIL=, USERNAME=, PASSWORD= override the defaults"
  task testadmin: :environment do
    abort "dev:testadmin is development only" unless Rails.env.development?

    username = ENV.fetch("USERNAME", "testadmin")
    email    = ENV.fetch("EMAIL", "testadmin@example.com")
    password = ENV.fetch("PASSWORD", "password")

    ApplicationRecord.transaction do
      ali    = Alias.by_email(email).first
      user   = ali&.user || User.find_by(username: username)
      person = user&.person || ali&.person || Person.create!

      user ||= User.new(username: username)
      user.person = person
      user.assign_attributes(
        admin: true,
        deleted_at: nil,
        password: password,
        password_confirmation: password
      )
      user.save!

      ali ||= Alias.new(name: "Test Admin", email: email)
      ali.person = person
      ali.user = user
      ali.verified_at ||= Time.current
      ali.save!

      person.update!(default_alias_id: ali.id) if person.default_alias_id.nil?

      puts "testadmin ready: #{email} / #{password} (user ##{user.id})"
    end
  end
end
