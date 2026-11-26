require "rails_helper"
require Rails.root.join("db/migrate/20261126130000_reserve_bot_username")

RSpec.describe Classify::Setup do
  it "is idempotent" do
    2.times { described_class.call! }
    expect(User.where(username: "hackorum-bot").count).to eq(1)
    expect(GlobalTag.where(name: Classify::KIND_TAGS + Classify::SIZE_TAGS + Classify::OUTCOME_TAGS).count).to eq(11)
    expect(GlobalTag.find_by(name: "enhancement")).to be_present
  end

  it "unretires its tags" do
    described_class.call!
    GlobalTag.find_by!(name: "minor").retire!
    described_class.call!
    expect(GlobalTag.find_by!(name: "minor").retired_at).to be_nil
  end

  it "creates a person-less bot with a reserved name" do
    bot = described_class.call!
    expect(bot).to have_attributes(person_id: nil, password_digest: nil)
    expect(NameReservation.find_by(name: "hackorum-bot")).to have_attributes(owner_type: "User", owner_id: bot.id)
    expect(Classify.bot_user).to eq(bot)
    expect(GlobalTag.find_by!(name: "bug")).to have_attributes(created_by: bot, retired_at: nil)
  end

  describe "bot name" do
    def system_reservation = NameReservation.create!(name: "hackorum-bot", owner_type: "System", owner_id: 0)

    # a migrated test db holds the system row already
    before { NameReservation.where(name: "hackorum-bot").delete_all }

    it "is reserved for the system by a migration when free" do
      ActiveRecord::Migration.suppress_messages { ReserveBotUsername.new.migrate(:up) }
      expect(NameReservation.find_by(name: "hackorum-bot")).to have_attributes(owner_type: "System", owner_id: 0)
      expect { create(:user, username: "hackorum-bot") }.to raise_error(ActiveRecord::RecordInvalid, /taken/)
    end

    it "is left alone by the migration when taken" do
      user = create(:user, username: "hackorum-bot")
      ActiveRecord::Migration.suppress_messages { ReserveBotUsername.new.migrate(:up) }
      expect(NameReservation.find_by(name: "hackorum-bot")).to have_attributes(owner_type: "User", owner_id: user.id)
    end

    it "takes over the system reservation" do
      system_reservation
      bot = described_class.call!
      expect(NameReservation.where(name: "hackorum-bot").sole).to have_attributes(owner_type: "User", owner_id: bot.id)
    end

    it "adopts a bare user with the name" do
      bare = User.create!(username: "hackorum-bot")
      expect(described_class.call!).to eq(bare)
    end

    it "refuses a real account holding the name" do
      real = create(:user, username: "Hackorum-Bot")
      expect { described_class.call! }.to raise_error(described_class::Error, /user #{real.id}/)
      bare = User.create!(username: "hackorum-bot2")
      bare.update_columns(username: "hackorum-bot", password_digest: "x")
      real.destroy!
      expect { described_class.call! }.to raise_error(described_class::Error, /real account/)
      bare.update_columns(password_digest: nil)
      create(:identity, user: bare)
      expect { described_class.call! }.to raise_error(described_class::Error, /real account/)
      expect(GlobalTag.count).to eq(0)
    end

    it "refuses a name reserved by someone else" do
      NameReservation.create!(name: "hackorum-bot", owner_type: "MailboxAddress", owner_id: 5)
      expect { described_class.call! }.to raise_error(described_class::Error, /reserved by MailboxAddress 5/)
      expect(User.where(username: "hackorum-bot")).to be_empty
    end
  end

  it "maps tags to kind and size" do
    expect(Classify.kind(%w[feature minor])).to eq("feature")
    expect(Classify.size(%w[feature minor])).to eq("minor")
    expect(Classify.kind(%w[minor])).to be_nil
    expect(Classify.size(%w[bug])).to be_nil
  end
end
