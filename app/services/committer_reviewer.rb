# frozen_string_literal: true

# Committing someone else's patch means reviewing the committed version. One
# rule, written as its own commit_people source so readers need not derive it.
class CommitterReviewer
  SOURCE = "committer"
  AUTHOR_ROLES = %w[author co_author].freeze

  def self.sync!(commit_ids) = new(commit_ids).sync!

  # one person by person id, email or name; two resolved people never match
  # by name alone
  def self.same_person?(a, b)
    return true if a.person_id.present? && a.person_id == b.person_id
    return true if a.raw_email.present? && b.raw_email.present? && a.raw_email.casecmp?(b.raw_email)
    return false if a.person_id.present? && b.person_id.present?

    a.raw_name.present? && b.raw_name.present? && a.raw_name.strip.casecmp?(b.raw_name.strip)
  end

  def initialize(commit_ids)
    @commit_ids = Array(commit_ids).uniq
  end

  def entries
    @entries ||= @commit_ids.filter_map do |commit_id|
      people = people_of(commit_id)
      committer = committer_of(people)
      next unless others_patch?(people, committer)
      next if people.any? { |p| p.source == "parsed" && p.role == "reviewer" && same?(p, committer) }

      { commit_id: commit_id, role: "reviewer", source: SOURCE,
        person_id: committer.person_id, raw_name: committer.raw_name, raw_email: committer.raw_email }
    end
  end

  # committed someone else's patch, whether or not a trailer already credits
  # the committer as reviewer
  def others_commit_ids
    @others_commit_ids ||= @commit_ids.select do |commit_id|
      people = people_of(commit_id)
      others_patch?(people, committer_of(people))
    end
  end

  def sync!
    return 0 if @commit_ids.empty?

    CommitPerson.transaction do
      CommitPerson.committer_sourced.where(commit_id: @commit_ids).delete_all
      CommitPerson.insert_all(entries) if entries.any?
    end
    entries.size
  end

  private

  def people_of(commit_id)
    @rows ||= CommitPerson.where(commit_id: @commit_ids, source: %w[parsed llm]).group_by(&:commit_id)
    @rows[commit_id] || []
  end

  def committer_of(people) = people.find { |p| p.source == "parsed" && p.role == CommitPerson::COMMITTER }

  def others_patch?(people, committer)
    return false unless committer

    authors = people.select { |p| AUTHOR_ROLES.include?(p.role) }
    authors.any? && authors.none? { |a| same?(a, committer) }
  end

  def same?(a, b) = self.class.same_person?(a, b)
end
