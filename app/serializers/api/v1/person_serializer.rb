module Api
  module V1
    class PersonSerializer < BaseSerializer
      STATS = %i[
        messages_sent messages_sent_hidden threads_started threads_started_hidden
        threads_joined threads_joined_hidden patches_sent patch_threads
        first_message_at last_message_at
      ].freeze

      PRELOAD = [ :default_alias, :aliases ].freeze

      def brief
        shown = shown_alias
        email = shown&.email
        {
          id: record.id,
          name: shown&.name || "Unknown",
          email: email,
          url: email && api_url("/people/#{ERB::Util.url_encode(email)}"),
          html_url: email && site_url(routes.person_path(email))
        }
      end

      def full
        stats = ProfileStats.new(record.id, sources: %w[parsed committer])
        brief.merge(
          aliases: record.aliases.with_sent_messages.order(:email, :id).pluck(:name, :email)
                         .map { |name, email| { name: name, email: email } },
          contributor_type: record.contributor_type,
          contributor_badge: record.contributor_badge,
          stats: STATS.index_with { |name| stats.public_send(name) }
        )
      end

      private

      def shown_alias
        record.default_alias ||
          record.aliases.select { |row| row.sender_count > 0 }.min_by { |row| [ row.email, row.id ] } ||
          record.aliases.min_by { |row| [ row.created_at, row.id ] }
      end
    end
  end
end
