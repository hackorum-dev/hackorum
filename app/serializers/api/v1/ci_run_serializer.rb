module Api
  module V1
    class CiRunSerializer < BaseSerializer
      COLUMNS = %i[
        id github_run_id run_attempt status head_sha pg_major queued_at started_at completed_at
        build_seconds test_seconds tests_total failed_tests image_ref image_digest created_at
      ].freeze

      def brief
        {
          **COLUMNS.index_with { |name| record.public_send(name) },
          image_pull_ref: helpers.ci_digest_ref(record),
          github_url: helpers.ci_github_run_url(record)
        }
      end
    end
  end
end
