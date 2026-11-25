require "rails_helper"

RSpec.describe "Mailbox names" do
  let(:user) { create(:user, username: "dutow") }
  let!(:mailbox) { Mailbox.grant!(user: user, login: "dutow") }

  def holder(name)
    r = NameReservation.find_by(name: name)
    r && [ r.owner_type, r.owner_id ]
  end

  it "keeps the old name claimed by the address after a username change" do
    user.update!(username: "zsolt")
    expect(holder("dutow")).to eq([ "MailboxAddress", mailbox.login_address.id ])
    expect(holder("zsolt")).to eq([ "User", user.id ])
    expect(build(:user, username: "dutow")).not_to be_valid
  end

  it "lets the owner take back a name held by an own address" do
    user.update!(username: "zsolt")
    expect(user.update(username: "Dutow")).to be(true)
    expect(holder("dutow")).to eq([ "User", user.id ])
    expect(holder("zsolt")).to be_nil
  end

  it "lets the owner rename to an own alias" do
    mailbox.add_alias("zsolt.parragi")
    expect(user.update(username: "zsolt.parragi")).to be(true)
    expect(holder("zsolt.parragi")).to eq([ "User", user.id ])
    expect(holder("dutow")).to eq([ "MailboxAddress", mailbox.login_address.id ])
  end

  it "does not let a user take another mailbox's address" do
    other = create(:user, username: "eve")
    expect(other.update(username: "dutow")).to be(false)
    mailbox.add_alias("zsolt.parragi")
    expect(other.update(username: "zsolt.parragi")).to be(false)
  end

  it "releases a plain username as before" do
    plain = create(:user, username: "plain")
    plain.update!(username: "plainer")
    expect(holder("plain")).to be_nil
  end

  it "frees a transferred name when the alias is removed" do
    mailbox.add_alias("zsolt")
    user.update!(username: "zsolt")
    user.update!(username: "third")
    mailbox.alias_addresses.find_by!(local_part: "zsolt").destroy!
    expect(holder("zsolt")).to be_nil
  end

  it "transfer! raises when there is no row" do
    expect { NameReservation.transfer!(name: "nope", to: user) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
