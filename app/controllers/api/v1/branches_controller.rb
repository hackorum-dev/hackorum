module Api
  module V1
    class BranchesController < BaseController
      COLUMNS = %w[patch_branches.updated_at patch_branches.id].freeze
      CURRENT = { nil => true, "true" => true, "false" => false }.freeze
      NO_RESULT = PatchCi::BranchQuery::NO_RESULT

      query_params :topic, :author, :state, :ci_status, :pg_major, :current, paged: true, on: :index

      def index
        branches, next_cursor = paginate(filtered, columns: COLUMNS) { |page| load(page) }
        render_page(BranchSerializer.brief_list(branches, context, repo_state: repo_state), next_cursor)
      end

      def show
        branch = load(PatchBranch.where(lineage_only: false, id: path_param(:id))).first
        raise ActiveRecord::RecordNotFound unless branch

        render json: BranchSerializer.new(branch, context, repo_state: repo_state).full
      end

      private

      def repo_state
        return @repo_state if defined?(@repo_state)
        @repo_state = PatchCiRepoState.current
      end

      def rows
        @rows ||= PatchCi::BranchRows.new(repo_state: repo_state)
      end

      def load(relation)
        rows.load(rows.health.with_reason(relation))
      end

      def filtered
        scope = current_param ? PatchBranch.current : PatchBranch.where(lineage_only: false)
        scope = scope.where(topic_id: topic_param) if params.key?(:topic)
        scope = scope.where(pg_major: pg_major_param) if params.key?(:pg_major)
        scope = by_ci_status(scope)
        scope = by_author(scope)
        rows.health.filter(scope, [ state_param ].compact)
      end

      def by_ci_status(scope)
        status = one_of(:ci_status, PatchCi::BranchQuery::RESULT_VALUES)
        return scope unless status
        scope.where(ci_status: status == NO_RESULT ? nil : status)
      end

      def by_author(scope)
        email = author_param
        return scope if email.nil?

        person = Person.find_by_email(email)
        person ? scope.joins(:message).where(messages: { sender_person_id: person.id }) : scope.none
      end

      def current_param
        CURRENT.fetch(string_param(:current)) { raise Api::InvalidParameter, "current must be true or false" }
      end

      def state_param
        one_of(:state, PatchCi::BranchHealth::BUCKETS)
      end

      def topic_param
        matching(:topic, PatchCi::BranchQuery::TOPIC_ID, "a numeric topic id")
      end

      def pg_major_param
        matching(:pg_major, PatchCi::BranchQuery::PG_MAJOR, "an integer")
      end

      def one_of(name, values)
        value = string_param(name)
        return value if value.nil? || values.include?(value)
        raise Api::InvalidParameter, "#{name} must be one of #{values.join(', ')}"
      end

      def matching(name, pattern, what)
        value = string_param(name).to_s
        raise Api::InvalidParameter, "#{name} must be #{what}" unless value.match?(pattern)
        value.to_i
      end
    end
  end
end
