# frozen_string_literal: true

module Search
  class CommitQuery
    ROLES = {
      reviewer: %w[reviewer],
      reporter: %w[reported_by],
      tester: %w[tested_by],
      author: %w[author co_author],
      committer: %w[committer]
    }.freeze

    KEY = "COALESCE(NULLIF(commits.cherry_picked_from_sha, ''), commits.sha)"

    def initialize(resolver:, warnings:)
      @resolver = resolver
      @warnings = warnings
      @unresolved = false
    end

    def unresolved?
      @unresolved
    end

    def topic_ids(sha:, conditions:)
      key_sets = []
      key_sets << sha_keys(sha) if sha.present?

      conditions.each do |condition|
        keys = condition_keys(condition)
        return CommitTopic.none.select(:topic_id) if keys.nil?

        key_sets << keys
      end

      scope = CommitTopic.joins(:commit)
      key_sets.each { |keys| scope = scope.where("#{KEY} IN (#{keys.to_sql})") }
      scope.select(:topic_id)
    end

    private

    def condition_keys(condition)
      key = condition[:key]
      value = condition[:value].to_s

      if ROLES.key?(key)
        role_keys(key, value, quoted: condition[:quoted])
      elsif key == :released
        released_keys(value)
      elsif key == :committed_after
        date_keys(">=", value)
      elsif key == :committed_before
        date_keys("<", value)
      end
    end

    def role_keys(role, value, quoted:)
      result = @resolver.resolve_author(value, quoted: quoted)
      @warnings.concat(result.warnings)
      if result.person_ids.empty?
        @unresolved = true
        return nil
      end

      Commit.joins(:commit_people).merge(CommitPerson.shown)
            .where(commit_people: { role: ROLES[role], person_id: result.person_ids })
            .select(Arel.sql(KEY))
    end

    def released_keys(value)
      if value.casecmp?("none")
        Commit.group(Arel.sql(KEY)).having("bool_and(commits.released_in IS NULL)").select(Arel.sql(KEY))
      else
        pattern = "^#{value.gsub('.', '\.')}(\\.|alpha|beta|rc|$)"
        Commit.where("commits.released_in ~ ?", pattern).select(Arel.sql(KEY))
      end
    end

    def date_keys(operator, value)
      date = DateParser.new(value).parse
      Commit.where("commits.committed_at #{operator} ?", date).select(Arel.sql(KEY))
    end

    def sha_keys(sha)
      Commit.where("commits.sha LIKE ?", "#{sha.downcase}%").select(Arel.sql(KEY))
    end
  end
end
