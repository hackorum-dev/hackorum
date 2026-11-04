module Topics
  class CreditCounts
    Entry = Struct.new(:name, :email, :total, :llm, :committer, keyword_init: true) do
      def llm_only? = llm.positive? && llm == total
    end

    def initialize(groups, sources:)
      @groups = groups
      @sources = sources
    end

    # role => [Entry], counted per logical change (a commit plus its backports)
    def by_role
      @by_role ||= begin
        change_of = @groups.each_with_object({}) do |group, map|
          group[:commit_ids].each { |id| map[id] = group[:sha] }
        end
        rows = CommitPerson.where(commit_id: change_of.keys, source: @sources)
                           .includes(person: :default_alias)
        grouped = rows.group_by(&:role)

        CommitPerson::DISPLAY_ORDER.each_with_object({}) do |role, acc|
          entries = people_groups(grouped[role] || []).map { |person_rows| entry_for(person_rows, change_of) }
          acc[role] = entries.sort_by { |e| [ -e.total, e.name.to_s.downcase ] } if entries.any?
        end
      end
    end

    private

    def people_groups(rows)
      linked, unlinked = rows.partition(&:person_id)
      groups = linked.group_by(&:person_id)
      names = groups.transform_values do |person_rows|
        (person_rows.filter_map { |row| row.raw_name.presence } +
          [ person_rows.first.person&.default_alias&.name ]).compact.to_set(&:downcase)
      end

      loose = unlinked.group_by do |row|
        key = row.raw_name.to_s.strip.downcase
        matches = names.select { |_, set| set.include?(key) }.keys
        matches.first if matches.one?
      end
      folded = loose.delete(nil) || []
      loose.each { |person_id, extra| groups[person_id].concat(extra) }
      groups.values + folded.group_by { |row| (row.raw_name.presence || row.raw_email).to_s.strip.downcase }.values
    end

    def entry_for(rows, change_of)
      per_change = rows.group_by { |row| change_of[row.commit_id] }
      alias_record = rows.filter_map { |row| row.person&.default_alias }.first
      Entry.new(
        name: alias_record&.name || common_name(rows) || rows.first.raw_email,
        email: alias_record&.email,
        total: per_change.size,
        llm: per_change.count { |_, change_rows| change_rows.all? { |row| row.source == "llm" } },
        committer: rows.any? { |row| row.source == CommitterReviewer::SOURCE }
      )
    end

    def common_name(rows)
      rows.filter_map { |row| row.raw_name.presence }.tally.min_by { |name, n| [ -n, name ] }&.first
    end
  end
end
