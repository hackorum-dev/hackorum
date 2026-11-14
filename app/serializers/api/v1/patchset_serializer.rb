module Api
  module V1
    # A message that carries patches.
    class PatchsetSerializer < BaseSerializer
      COLUMNS = %w[id topic_id sender_person_id subject created_at].freeze
      PRELOAD = [ :topic, { sender_person: PersonSerializer::PRELOAD } ].freeze

      def self.load(relation)
        relation.select(COLUMNS.map { |name| Message.arel_table[name] }).preload(PRELOAD)
      end

      def self.brief_list(records, context, **extras)
        super(records, context, page_data: PatchsetPageData.new(records), **extras)
      end

      def brief
        {
          message_id: record.id,
          number: page_data.number(record.id),
          url: api_url("/messages/#{record.id}"),
          html_url: message_html_url(record),
          created_at: record.created_at,
          subject: record.subject,
          sender: PersonSerializer.new(record.sender_person, context).brief,
          topic: topic_ref(record.topic),
          files: AttachmentSerializer.brief_list(page_data.files(record.id), context),
          changed_paths: page_data.changed_paths(record.id),
          branch: branch,
          download_url: site_url(routes.message_patchset_path(record.id)),
          **lineage
        }
      end

      private

      def page_data
        @page_data ||= extras[:page_data] || PatchsetPageData.new([ record ])
      end

      def lineage
        step = page_data.step(record.id)
        { lineage: step && LineageSerializer.step(step) }
      end

      def branch
        row = page_data.branch(record.id)
        row && BranchSerializer.new(row, context).ref
      end
    end
  end
end
