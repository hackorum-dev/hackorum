module Classify
  class Setup
    Error = Class.new(StandardError)

    DESCRIPTIONS = {
      "feature" => "New user-visible capability: syntax, options, functions, views, GUCs, tools",
      "performance" => "Faster or cheaper, no new user-facing capability",
      "bug" => "Bug report or fix, incl. fixes for recently committed features",
      "refactor" => "Cleanup, refactoring, preparatory work without user-visible effect",
      "docs" => "Documentation-only change",
      "tests-build" => "Tests, test infrastructure, CI, build system, tooling",
      "discussion" => "Process, meta or design discussion not about a code change",
      "major" => "Headline release-notes item or multi-cycle project",
      "moderate" => "Self-contained feature with clear user value, limited scope",
      "minor" => "Small addition: tab completion, one flag, wording, micro-optimization",
      "not-a-bug" => "Reported behaviour is expected, documented, user error or not our problem",
      "enhancement" => "Extends or improves a feature that already exists"
    }.freeze

    def self.call!
      new.call!
    end

    def call!
      bot = bot!

      DESCRIPTIONS.each do |name, description|
        tag = GlobalTag.find_or_create_by!(name:) do |t|
          t.created_by = bot
          t.description = description
        end
        tag.unretire! if tag.retired?
      end
      bot
    end

    private

    # never adopt a real account; the name may be held only by the system or the bot
    def bot!
      user = User.where("lower(username) = ?", BOT_USERNAME).first
      if user && (user.username != BOT_USERNAME || user.person_id || user.password_digest || user.identities.exists?)
        raise Error, "user #{user.id} (#{user.username}) holds #{BOT_USERNAME} and looks like a real account; " \
                     "rename it before running setup"
      end

      reservation = NameReservation.find_by(name: BOT_USERNAME)
      system = reservation && reservation.owner_type == "System" && reservation.owner_id.zero?
      ours = reservation && user && reservation.owner_type == "User" && reservation.owner_id == user.id
      if reservation && !system && !ours
        raise Error, "#{BOT_USERNAME} is reserved by #{reservation.owner_type} #{reservation.owner_id}; free it before running setup"
      end

      User.transaction do
        reservation.destroy! if system
        user ||= User.create!(username: BOT_USERNAME, verified_at: Time.current)
        NameReservation.reserve!(name: BOT_USERNAME, owner: user)
        user
      end
    end
  end
end
