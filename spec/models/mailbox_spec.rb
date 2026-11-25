require "rails_helper"

RSpec.describe Mailbox, type: :model do
  let(:user) { create(:user, username: "dutow") }

  it "grants a mailbox with a login address and an unusable password" do
    mailbox = Mailbox.grant!(user: user, login: " Dutow ")
    expect(mailbox.login_local_part).to eq("dutow")
    expect(mailbox.quota_mb).to eq(5120)
    expect(mailbox.password_hash).to start_with("{SHA512-CRYPT}$6$")
    expect(user.reload.mailbox).to eq(mailbox)
  end

  it "allows one mailbox per user" do
    Mailbox.grant!(user: user, login: "dutow")
    expect { Mailbox.grant!(user: user, login: "other") }.to raise_error(ActiveRecord::RecordInvalid)
    expect(MailboxAddress.where(local_part: "other")).to be_empty
  end

  it "refuses deleted and unverified users" do
    expect { Mailbox.grant!(user: create(:user, deleted_at: Time.current), login: "a1") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { Mailbox.grant!(user: create(:user, verified_at: nil), login: "a2") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "validates the quota" do
    [ 0, -1, 102_401 ].each do |q|
      expect { Mailbox.grant!(user: user, login: "dutow", quota_mb: q) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  it "turns a unique index hit into a validation error" do
    grant_mailbox(login: "taken")
    allow(NameReservation).to receive(:find_by).and_return(nil)
    allow_any_instance_of(ActiveRecord::Validations::UniquenessValidator).to receive(:validate_each)
    expect { Mailbox.grant!(user: user, login: "taken") }.to raise_error(ActiveRecord::RecordInvalid, /is already taken/)
    expect(Mailbox.where(user_id: user.id)).to be_empty
  end

  it "disables and enables" do
    mailbox = grant_mailbox
    mailbox.disable!
    expect(mailbox).to be_disabled
    expect(Mailbox.enabled).not_to include(mailbox)
    mailbox.enable!
    expect(Mailbox.enabled).to include(mailbox)
  end

  it "does not enable the mailbox of a deleted user" do
    mailbox = grant_mailbox
    mailbox.disable!
    mailbox.user.update_columns(deleted_at: Time.current)
    expect(mailbox.enable!).to be(false)
    expect(mailbox.errors[:user]).to include("is deleted")
    expect(mailbox.reload).to be_disabled
  end
end
