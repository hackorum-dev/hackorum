class CleanupUnverifiedUsersJob < ApplicationJob
  queue_as :default

  def perform
    User.cleanup_unverified!
    UserToken.cleanup_expired!
  end
end
