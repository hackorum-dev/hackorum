require "rails_helper"

RSpec.describe MailboxAddress, type: :model do
  let(:user) { create(:user, username: "dutow") }
  let(:mailbox) { Mailbox.grant!(user: user, login: "dutow") }

  it "accepts valid local parts" do
    %w[a zsolt.parragi a_b-c x1 info].each do |lp|
      expect(mailbox.add_alias(lp)).to be_persisted, lp
    end
  end

  it "rejects invalid local parts" do
    [ "", "a..b", ".a", "a.", "_a", "a+b", "dutow@hackorum.dev", "a b", "x" * 65 ].each do |lp|
      addr = mailbox.add_alias(lp)
      expect(addr).not_to be_persisted, lp
      expect(addr.errors[:local_part]).to be_present
    end
  end

  it "normalizes case and whitespace" do
    expect(mailbox.add_alias(" Zsolt.Parragi ").local_part).to eq("zsolt.parragi")
  end

  it "refuses a login that the mailserver's unanchored account match would mix up with a system account" do
    %w[iver p a.p myapp xreceiver].each do |login|
      owner = create(:user, username: "owner#{login.delete('.')}")
      expect { Mailbox.grant!(user: owner, login: login) }
        .to raise_error(ActiveRecord::RecordInvalid, /conflicts with a system mail account/), login
    end
    %w[apple pat receivers].each { |login| expect(grant_mailbox(login: login)).to be_persisted, login }
    expect(mailbox.add_alias("myapp")).to be_persisted
  end

  it "rejects system names, allows role names" do
    expect(mailbox.add_alias("postmaster").errors[:local_part]).to include("is reserved")
    expect(mailbox.add_alias("security")).to be_persisted
  end

  it "shares the owner's username reservation for the login" do
    mailbox
    res = NameReservation.find_by(name: "dutow")
    expect([ res.owner_type, res.owner_id ]).to eq([ "User", user.id ])
  end

  it "claims a free name and blocks users and teams from it" do
    addr = mailbox.add_alias("zsolt.parragi")
    res = NameReservation.find_by(name: "zsolt.parragi")
    expect([ res.owner_type, res.owner_id ]).to eq([ "MailboxAddress", addr.id ])
    expect(build(:user, username: "Zsolt.Parragi").tap(&:valid?).errors[:username]).to include("is already taken")
    expect(build(:team, name: "zsolt.parragi").tap(&:valid?).errors[:name]).to include("is already taken")
  end

  it "refuses names held by others" do
    create(:user, username: "alice")
    create(:team, name: "core")
    grant_mailbox(login: "bob").add_alias("bobby")
    %w[alice core bob bobby].each do |lp|
      expect(mailbox.add_alias(lp).errors[:local_part]).to include("is already taken"), lp
    end
  end

  it "frees the name when an alias is removed" do
    mailbox.add_alias("zsolt.parragi").destroy!
    expect(NameReservation.find_by(name: "zsolt.parragi")).to be_nil
  end

  it "keeps the username reservation when the matching address goes away" do
    mailbox.destroy!
    expect(NameReservation.find_by(name: "dutow").owner_type).to eq("User")
  end

  it "does not let the login address be removed or changed" do
    login = mailbox.login_address
    expect(login.destroy).to be(false)
    expect { login.update!(local_part: "other") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(login.reload.local_part).to eq("dutow")
  end

  it "can be validated and saved after reloading" do
    addr = mailbox.add_alias("zsolt.parragi")
    reloaded = described_class.find(addr.id)
    expect(reloaded).to be_valid
    expect(reloaded.save).to be(true)
    expect(mailbox.login_address.reload).to be_valid
  end

  it "reports a name lost to a concurrent claim on add_alias" do
    NameReservation.create!(name: "raced", owner_type: "User", owner_id: create(:user).id)
    allow_any_instance_of(described_class).to receive(:name_available)
    addr = mailbox.add_alias("raced")
    expect(addr).not_to be_persisted
    expect(addr.errors[:local_part]).to include("is already taken")
    expect(described_class.where(local_part: "raced")).to be_empty
  end

  it "reports a name lost to a concurrent claim on grant!" do
    NameReservation.create!(name: "raced", owner_type: "User", owner_id: create(:user).id)
    allow_any_instance_of(described_class).to receive(:name_available)
    expect { Mailbox.grant!(user: user, login: "raced") }.to raise_error(ActiveRecord::RecordInvalid, /is already taken/)
    expect(Mailbox.where(user_id: user.id)).to be_empty
    expect(described_class.where(local_part: "raced")).to be_empty
  end

  it "frees all names when the mailbox is destroyed" do
    mailbox.add_alias("zsolt.parragi")
    mailbox.destroy!
    expect(NameReservation.find_by(name: "zsolt.parragi")).to be_nil
    expect(MailboxAddress.count).to eq(0)
  end
end
