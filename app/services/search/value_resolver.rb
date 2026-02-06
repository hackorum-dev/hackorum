# frozen_string_literal: true

module Search
  # Resolves special values in search queries to actual database IDs.
  # Handles: me, team names, contributor types, email/name detection
  class ValueResolver
    CONTRIBUTOR_TYPES = %w[
      contributor
      committer
      core_team
      major_contributor
      significant_contributor
      past_major_contributor
      past_significant_contributor
    ].freeze

    # Result types for author resolution
    Result = Struct.new(:type, :person_ids, :alias_ids, :user_ids, :warnings, keyword_init: true) do
      def self.empty(warning: nil)
        new(type: :empty, person_ids: [], alias_ids: [], user_ids: [], warnings: Array(warning))
      end

      def self.persons(ids, warnings: [])
        new(type: :persons, person_ids: Array(ids), alias_ids: [], user_ids: [], warnings: warnings)
      end

      def self.aliases(ids, warnings: [])
        new(type: :aliases, person_ids: [], alias_ids: Array(ids), user_ids: [], warnings: warnings)
      end

      def self.users(ids, warnings: [])
        new(type: :users, person_ids: [], alias_ids: [], user_ids: Array(ids), warnings: warnings)
      end
    end

    # Result type for tag resolution
    TagResult = Struct.new(:tag_name, :user_ids, :warnings, keyword_init: true) do
      def self.empty(warning: nil)
        new(tag_name: nil, user_ids: nil, warnings: Array(warning))
      end
    end

    def initialize(user:)
      @user = user
    end

    # Resolve author value (from:, starter:, last_from:)
    # Returns Result with person_ids or alias_ids
    def resolve_author(value, quoted: false)
      return Result.empty(warning: "Empty author value") if value.blank?

      # Check special values in order of priority
      return resolve_me_author if value == "me"
      return resolve_contributor_type(value) if contributor_type?(value)

      team_result = resolve_team_author(value)
      return team_result if team_result

      # Fall back to name/email search
      resolve_name_or_email(value, quoted: quoted)
    end

    # Resolve state value (unread:, starred:, notes:, etc.)
    # Returns Result with user_ids
    def resolve_state_subject(value)
      return Result.empty(warning: "Empty state value") if value.blank?

      if value == "me"
        return Result.empty(warning: "Must be signed in to use 'me'") unless @user
        return Result.users([@user.id])
      end

      # Check for team (must be member for state selectors due to privacy)
      team = find_team_for_state(value)
      if team
        user_ids = team_member_user_ids(team)
        return Result.users(user_ids)
      end

      Result.empty(warning: "Invalid state subject: #{value}")
    end

    # Resolve tag value (tag:)
    # Returns TagResult with tag_name (simple tag names only, no @ syntax)
    def resolve_tag(value)
      return TagResult.empty(warning: "Empty tag value") if value.blank?
      return TagResult.empty(warning: "Must be signed in to use tag search") unless @user

      # Simple tag name - all accessible sources
      TagResult.new(tag_name: value.downcase, user_ids: nil, warnings: [])
    end

    # Check if value is a contributor type keyword
    def contributor_type?(value)
      CONTRIBUTOR_TYPES.include?(value.to_s.downcase)
    end

    # Check if value contains @ (email indicator)
    def email_value?(value)
      value.to_s.include?("@")
    end

    private

    def resolve_me_author
      return Result.empty(warning: "Must be signed in to use 'me'") unless @user

      person_id = @user.person_id
      return Result.empty(warning: "User has no associated person") unless person_id

      Result.persons([person_id])
    end

    def resolve_contributor_type(value)
      normalized = value.to_s.downcase

      person_ids = if normalized == "contributor"
        # Match any contributor type
        ContributorMembership.distinct.pluck(:person_id)
      else
        # Match specific contributor type
        ContributorMembership.where(contributor_type: normalized).pluck(:person_id)
      end

      if person_ids.empty?
        Result.empty(warning: "No contributors found for type: #{value}")
      else
        Result.persons(person_ids)
      end
    end

    def resolve_team_author(value)
      team = find_accessible_team(value)
      return nil unless team

      # Get all person_ids for team members
      person_ids = User.joins(:team_members)
                       .where(team_members: { team_id: team.id })
                       .pluck(:person_id)
                       .compact

      if person_ids.empty?
        Result.empty(warning: "Team '#{value}' has no members")
      else
        Result.persons(person_ids)
      end
    end

    def resolve_name_or_email(value, quoted:)
      if email_value?(value)
        # Value contains @ - search emails only
        resolve_email(value, quoted: quoted)
      else
        # No @ - search both name and email
        resolve_name_and_email(value, quoted: quoted)
      end
    end

    def resolve_email(value, quoted:)
      aliases = if quoted
        Alias.where("LOWER(email) = LOWER(?)", value)
      else
        Alias.where("email ILIKE ?", "%#{sanitize_like(value)}%")
      end

      person_ids = aliases.where.not(person_id: nil).distinct.pluck(:person_id)

      if person_ids.empty?
        Result.empty(warning: "No matching email found: #{value}")
      else
        Result.persons(person_ids)
      end
    end

    def resolve_name_and_email(value, quoted:)
      aliases = if quoted
        Alias.where("LOWER(name) = LOWER(?) OR LOWER(email) = LOWER(?)", value, value)
      else
        pattern = "%#{sanitize_like(value)}%"
        Alias.where("name ILIKE ? OR email ILIKE ?", pattern, pattern)
      end

      person_ids = aliases.where.not(person_id: nil).distinct.pluck(:person_id)

      if person_ids.empty?
        Result.empty(warning: "No matching author found: #{value}")
      else
        Result.persons(person_ids)
      end
    end

    # Find a team that the user can access for author queries (from:, starter:)
    # Visible/open teams are accessible to everyone
    # Private teams require membership
    def find_accessible_team(name)
      # First check if it's a team at all
      team = Team.find_by("LOWER(name) = LOWER(?)", name)
      return nil unless team

      # Check accessibility
      return team if team.accessible_to?(@user)

      nil
    end

    # Find a team for state queries (unread:, starred:, notes:)
    # Only accessible if user is a member (privacy requirement)
    def find_team_for_state(name)
      return nil unless @user

      Team.joins(:team_members)
          .where(team_members: { user_id: @user.id })
          .find_by("LOWER(teams.name) = LOWER(?)", name)
    end

    def team_member_user_ids(team)
      TeamMember.where(team_id: team.id).pluck(:user_id)
    end

    def sanitize_like(value)
      ActiveRecord::Base.sanitize_sql_like(value)
    end
  end
end
