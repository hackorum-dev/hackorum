module Api
  module V1
    class TopicSerializer < BaseSerializer
      COLUMNS = %i[
        created_at last_message_at message_count participant_count contributor_participant_count
        highest_contributor_type has_attachments commit_count last_commit_at
      ].freeze
      COMMITFEST_URL = "https://commitfest.postgresql.org".freeze
      MAX_PARTICIPANTS = 50
      PRELOAD = { creator_person: PersonSerializer::PRELOAD, last_sender_person: PersonSerializer::PRELOAD }.freeze

      def self.brief_list(records, context, **extras)
        super(records, context, page_data: TopicPageData.new(records, user: context.user), **extras)
      end

      # TopicParticipant rows of one person, each with its topic loaded
      def self.participation_list(rows, context)
        page_data = TopicPageData.new(rows.map(&:topic), user: context.user)
        rows.map { |row| new(row.topic, context, page_data: page_data).with_participation(row) }
      end

      def ref
        {
          id: record.id,
          slug: record.slug,
          title: record.title,
          url: api_url("/topics/#{record.id}"),
          html_url: site_url(routes.topic_path(record.id))
        }
      end

      def brief
        {
          **ref,
          **COLUMNS.index_with { |name| record.public_send(name) },
          creator: person(record.creator_person),
          last_sender: record.last_sender_person && person(record.last_sender_person),
          mailing_lists: page_data.mailing_lists(record.id).map do |list|
            { identifier: list.identifier, display_name: list.display_name }
          end,
          commitfest: commitfest,
          ci: ci,
          me: me
        }
      end

      def full
        brief.merge(
          me: me&.merge(first_unread_message_id: page_data.me_data.first_unread_message_id(record)),
          participants: participants,
          commitfest_patches: commitfest_patches,
          patchset_count: record.messages.where(is_patch_submission: true).count,
          links: link_names.index_with { |name| api_url("/topics/#{record.id}/#{name}") }
        )
      end

      def with_participation(row)
        brief.merge(
          participation: {
            message_count: row.message_count,
            first_message_at: row.first_message_at,
            last_message_at: row.last_message_at,
            started: record.creator_person_id == row.person_id
          }
        )
      end

      private

      def page_data
        @page_data ||= extras[:page_data] || TopicPageData.new([ record ], user: context.user)
      end

      def me
        page_data.me_data&.for(record)
      end

      def link_names
        names = %i[messages patchsets commits]
        lineage = context.feature?(LineageSerializer::FEATURE) && PatchsetRun.done.exists?(topic_id: record.id)
        lineage ? names + %i[lineage] : names
      end

      def person(record)
        PersonSerializer.new(record, context).brief
      end

      def commitfest
        summary = page_data.commitfest(record.id)
        return unless summary

        {
          name: summary[:commitfest_name],
          status: summary[:status],
          commitfest_url: "#{COMMITFEST_URL}/#{summary[:commitfest_external_id]}/",
          patch_url: "#{COMMITFEST_URL}/patch/#{summary[:patch_external_id]}/",
          committed: summary[:committed]
        }
      end

      def ci
        row = page_data.ci(record.id)
        return unless row

        {
          state: row.health_bucket,
          ci_status: row.ci_status,
          branch_id: row.id,
          branch_name: row.branch_name,
          url: api_url("/branches/#{row.id}")
        }
      end

      def participants
        rows = record.topic_participants
                     .order(message_count: :desc, first_message_at: :asc, id: :asc)
                     .limit(MAX_PARTICIPANTS)
                     .preload(person: [ *PersonSerializer::PRELOAD, :contributor_memberships ])
        rows.map do |row|
          {
            person: person(row.person),
            message_count: row.message_count,
            first_message_at: row.first_message_at,
            last_message_at: row.last_message_at,
            contributor_type: row.person.contributor_type
          }
        end
      end

      def commitfest_patches
        Topics::CommitfestSummary.new(record).patches.map do |patch|
          {
            external_id: patch.external_id,
            title: patch.title,
            status: patch.status,
            commitfest_name: patch.commitfest_name,
            reviewers: patch.reviewers,
            committer: patch.committer,
            tags: patch.tags,
            ci_status: patch.ci_status,
            url: "#{COMMITFEST_URL}/patch/#{patch.external_id}/"
          }
        end
      end
    end
  end
end
