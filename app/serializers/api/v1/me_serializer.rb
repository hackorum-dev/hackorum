module Api
  module V1
    class MeSerializer
      def initialize(context)
        @context = context
      end

      def full
        user = @context.user
        token = @context.token
        {
          username: user.username,
          person: user.person && PersonSerializer.new(user.person, @context).brief,
          emails: user.aliases.where.not(verified_at: nil).distinct.order(:email).pluck(:email),
          features: Feature::NAMES.select { |name| @context.feature?(name) },
          send_authorized: user.can_send_email?,
          token: { name: token.name, created_at: token.created_at, expires_at: token.expires_at }
        }
      end
    end
  end
end
