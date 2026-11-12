module Api
  module V1
    # A change with its backports, as Commit.group_backports gives it.
    class CommitGroupSerializer < BaseSerializer
      LINK_SOURCES = %w[trailer].freeze
      # what group_backports reads; the body is left in the database
      COLUMNS = %w[id sha subject committed_at committer_name branches released_in cherry_picked_from_sha].freeze

      def self.brief_list(records, context, page_data: CommitPageData.new(records), **extras)
        super(records, context, page_data: page_data, **extras)
      end

      def brief
        {
          sha: record[:sha],
          subject: record[:subject],
          committed_at: record[:committed_at],
          committer_name: record[:committer_name],
          url: helpers.commit_web_url(record[:sha]),
          branches: record[:branches].map { |row| row.slice(:branch, :version, :released_in) },
          people: people,
          **lineage
        }
      end

      private

      def page_data
        @page_data ||= extras[:page_data] || CommitPageData.new([ record ])
      end

      def people
        page_data.credits(record).map do |credit|
          person = credit.person && PersonSerializer.new(credit.person, context).brief
          entry = { role: credit.role, name: person ? person[:name] : credit.name, person: person }
          page_data.lineage ? entry.merge(source: credit.source) : entry
        end
      end

      # only for a caller with the feature
      def lineage
        data = page_data.lineage
        data ? { link_source: data.link_source(record), verdict: data.verdict(record) } : {}
      end
    end
  end
end
