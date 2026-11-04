# frozen_string_literal: true

# Committing someone else's patch means reviewing the committed version. One
# rule, written as its own commit_people source so readers need not derive it.
class CommitterReviewer
  SOURCE = "committer"
  AUTHOR_ROLES = %w[author co_author].freeze

  def self.sync!(commit_ids) = new(commit_ids).sync!

  def initialize(commit_ids)
    @commit_ids = Array(commit_ids).uniq
  end

  def entries
    @entries ||= begin
      rows = CommitPerson.where(commit_id: @commit_ids, source: %w[parsed llm]).group_by(&:commit_id)
      @commit_ids.filter_map do |commit_id|
        people = rows[commit_id] || []
        committer = people.find { |p| p.source == "parsed" && p.role == CommitPerson::COMMITTER }
        next unless committer

        authors = people.select { |p| AUTHOR_ROLES.include?(p.role) }
        next if authors.empty? || authors.any? { |a| same?(a, committer) }
        next if people.any? { |p| p.source == "parsed" && p.role == "reviewer" && same?(p, committer) }

        { commit_id: commit_id, role: "reviewer", source: SOURCE,
          person_id: committer.person_id, raw_name: committer.raw_name, raw_email: committer.raw_email }
      end
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

  def same?(a, b)
    (a.person_id.present? && a.person_id == b.person_id) ||
      (a.raw_email.present? && b.raw_email.present? && a.raw_email.casecmp?(b.raw_email)) ||
      (a.raw_name.present? && b.raw_name.present? && a.raw_name.strip.casecmp?(b.raw_name.strip))
  end
end
