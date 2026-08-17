namespace :people do
  # table name => columns pointing at people.id
  PERSON_REFERENCES = {
    "CommitPerson" => [ :person_id ],
    "ContributorMembership" => [ :person_id ],
    "Mention" => [ :person_id ],
    "Message" => [ :sender_person_id ],
    "TopicParticipant" => [ :person_id ],
    "Topic" => [ :creator_person_id, :last_sender_person_id ]
  }.freeze

  def person_leftovers(person_id)
    PERSON_REFERENCES.flat_map do |model_name, columns|
      model = model_name.constantize
      columns.filter_map do |column|
        count = model.where(column => person_id).count
        "#{model.table_name}.#{column}=#{count}" if count > 0
      end
    end
  end

  # A person with no aliases and no user is unreachable in the UI. Rows still
  # pointing at it are leftovers from a half-finished merge.
  desc "List people with no aliases and no user that still have rows pointing at them"
  task orphans: :environment do
    ids = Person.where.not(id: Alias.select(:person_id))
                .where.not(id: User.select(:person_id))
                .pluck(:id)

    found = 0
    ids.each do |id|
      leftovers = person_leftovers(id)
      next if leftovers.empty?

      found += 1
      puts "person #{id}: #{leftovers.join(' ')}"

      # The alias that was moved away is the best hint at where these belong.
      CommitPerson.where(person_id: id).distinct.pluck(:raw_email).compact.each do |email|
        target = Person.find_by_email(email)
        puts "  raw_email #{email} -> person #{target&.id || 'none'} #{target&.display_name}"
      end
    end

    puts found.zero? ? "no orphans with leftover rows" : "#{found} orphan(s) found"
  end

  desc "Finish a half-done merge: move an orphan's leftover rows onto TARGET. SOURCE= TARGET= ADMIN="
  task finish_merge: :environment do
    source = Person.find(Integer(ENV.fetch("SOURCE")))
    target = Person.find(Integer(ENV.fetch("TARGET")))
    admin = User.find_by(username: ENV.fetch("ADMIN"))

    abort "no such admin: #{ENV['ADMIN']}" unless admin&.admin?
    abort "source #{source.id} still has aliases, use the admin merge UI instead" if source.aliases.exists?

    puts "before: #{person_leftovers(source.id).join(' ')}"

    result = PersonMergeService.new(
      source_person: source,
      target_person: target,
      merged_by: admin
    ).call

    abort "merge failed: #{result.error}" unless result.success?
    puts "person #{source.id} merged into #{target.id} (#{target.display_name})"
  end
end
