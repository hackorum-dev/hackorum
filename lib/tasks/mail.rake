namespace :mail do
  desc "List users and teams whose names collide with system or role names"
  task name_conflicts: :environment do
    special = NameReservation::RESERVED_NAMES + NameReservation::ROLE_NAMES
    lines = []
    User.where("lower(username) IN (?)", special).order(:id).each { |u| lines << "User #{u.id} #{u.username}" }
    Team.where("lower(name) IN (?)", special).order(:id).each { |t| lines << "Team #{t.id} #{t.name}" }
    puts(lines.empty? ? "none" : lines)
  end

  desc "Write mailserver account files from mailboxes"
  task render: :environment do
    result = MailConfig::Renderer.call
    puts(result == :skipped ? "skipped" : (result.empty? ? "unchanged" : result.join(" ")))
  rescue MailConfig::Renderer::MissingFragment => e
    abort e.message
  end
end
