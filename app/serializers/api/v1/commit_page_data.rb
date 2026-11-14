module Api
  module V1
    # The credited people of commit groups, loaded once for all of them.
    class CommitPageData
      # in the order a credit made of several rows names its source
      SOURCES = [ "parsed", CommitterReviewer::SOURCE, "llm" ].freeze
      COLUMNS = %i[id commit_id role source raw_name raw_email person_id].freeze

      Credit = Struct.new(:role, :person, :rows) do
        def name
          rows.filter_map { |row| row.raw_name.presence&.strip }.tally.min_by { |name, count| [ -count, name ] }&.first
        end

        def named?
          person.present? || name.present?
        end

        def sort_key
          [ (person&.default_alias&.name || name).to_s.downcase, person&.id || 0 ]
        end

        def source
          SOURCES.find { |source| rows.any? { |row| row.source == source } }
        end

        def same?(row)
          rows.any? { |known| CommitterReviewer.same_person?(known, row) } || alias_name?(row.raw_name)
        end

        private

        def alias_name?(raw_name)
          known = person&.default_alias&.name
          known.present? && raw_name.present? && known.strip.casecmp?(raw_name.strip)
        end
      end

      # the lineage data of the thread, nil outside a thread
      attr_reader :lineage

      def initialize(groups, lineage: nil)
        @commit_ids = groups.flat_map { |group| group[:commit_ids] }
        @lineage = lineage
      end

      # one credit per role and person over the commits of the group
      def credits(group)
        rows = group[:commit_ids].flat_map { |id| rows_by_commit.fetch(id, []) }.group_by(&:role)
        CommitPerson::DISPLAY_ORDER.flat_map do |role|
          merged(role, rows.fetch(role, [])).select(&:named?).sort_by(&:sort_key)
        end
      end

      private

      def rows_by_commit
        @rows_by_commit ||= @commit_ids.empty? ? {} : CommitPerson.shown
          .where(commit_id: @commit_ids, source: SOURCES).select(COLUMNS).order(:id)
          .preload(person: PersonSerializer::PRELOAD).group_by(&:commit_id)
      end

      # a row without a person joins the one credit it matches by email or
      # name; matching several people, it stays apart
      def merged(role, rows)
        linked, loose = rows.partition(&:person)
        people = linked.group_by(&:person_id).values.map { |group| Credit.new(role, group.first.person, group) }
        unlinked = []
        loose.each do |row|
          matches = people.select { |credit| credit.same?(row) }
          credit = matches.first if matches.one?
          credit ||= unlinked.find { |known| known.same?(row) }
          unlinked << (credit = Credit.new(role, nil, [])) unless credit
          credit.rows << row
        end
        people + unlinked
      end
    end
  end
end
