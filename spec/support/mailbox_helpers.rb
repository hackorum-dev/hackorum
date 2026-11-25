module MailboxHelpers
  def grant_mailbox(user: nil, login: nil, **opts)
    @mailbox_seq = (@mailbox_seq || 0) + 1
    user ||= create(:user, username: "mbxuser#{SecureRandom.hex(3)}#{@mailbox_seq}")
    Mailbox.grant!(user: user, login: login || user.username, **opts)
  end
end

RSpec.configure { |config| config.include MailboxHelpers }
