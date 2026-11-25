require "rails_helper"

RSpec.describe Mailbox, "password", type: :model do
  let(:user) { create(:user, username: "dutow", password: "site password 1", password_confirmation: "site password 1") }
  let(:mailbox) { Mailbox.grant!(user: user, login: "dutow") }

  it "stores a verifiable hash" do
    expect(mailbox.change_password("a long mail password")).to be(true)
    expect(MailPasswordHash.matches?(mailbox.reload.password_hash, "a long mail password")).to be(true)
  end

  it "accepts multibyte characters and spaces" do
    pw = "jelszó árvíztűrő 12"
    expect(mailbox.change_password(pw)).to be(true)
    expect(MailPasswordHash.matches?(mailbox.password_hash, pw)).to be(true)
  end

  it "rejects short, long and control character passwords" do
    before = mailbox.password_hash
    {
      "short" => "is too short (minimum is 12 characters)",
      "x" * 129 => "is too long (maximum is 128 characters)",
      "twelve chars\nand more" => "contains invalid characters",
      "tab\tinside password" => "contains invalid characters"
    }.each do |pw, message|
      expect(mailbox.change_password(pw)).to be(false), pw.inspect
      expect(mailbox.errors[:password]).to eq([ message ])
    end
    expect(mailbox.reload.password_hash).to eq(before)
  end

  it "rejects the site password" do
    before = mailbox.password_hash
    expect(mailbox.change_password("site password 1")).to be(false)
    expect(mailbox.errors[:password]).to include("must differ from your site password")
    expect(mailbox.reload.password_hash).to eq(before)
  end

  it "works for users without a site password" do
    user.update_columns(password_digest: nil)
    expect(mailbox.change_password("a long mail password")).to be(true)
  end

  it "fails on non-string input" do
    expect(mailbox.change_password(nil)).to be(false)
    expect(mailbox.errors[:password]).to be_present
  end

  it "keeps errors of other attributes" do
    mailbox.errors.add(:quota_mb, "is bad")
    mailbox.change_password("short")
    expect(mailbox.errors[:quota_mb]).to eq([ "is bad" ])
  end

  it "does not persist other pending changes" do
    mailbox.quota_mb = 7
    expect(mailbox.change_password("a long mail password")).to be(true)
    expect(mailbox.reload.quota_mb).to eq(5120)
  end

  it "generates a password" do
    pw = mailbox.generate_password!
    expect(pw).to match(/\A[A-Za-z0-9]{24}\z/)
    expect(MailPasswordHash.matches?(mailbox.reload.password_hash, pw)).to be(true)
  end

  describe "commit callbacks" do
    let(:fired) { [] }
    let(:callback) do
      log = fired
      -> { log << true }
    end

    before do
      mailbox
      Mailbox.after_commit(&callback)
    end

    after { Mailbox.skip_callback(:commit, :after, &callback) }

    it "fire on change and generate, and bump updated_at" do
      old = mailbox.updated_at
      expect(mailbox.change_password("a long mail password")).to be(true)
      expect(fired.size).to eq(1)
      expect(mailbox.reload.updated_at).to be > old
      mailbox.generate_password!
      expect(fired.size).to eq(2)
    end

    it "do not fire on failure" do
      mailbox.change_password("short")
      expect(fired).to be_empty
    end
  end
end
