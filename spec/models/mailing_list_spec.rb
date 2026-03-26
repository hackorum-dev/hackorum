require "rails_helper"

RSpec.describe MailingList, type: :model do
  describe "validations" do
    subject { build(:mailing_list) }

    it { is_expected.to validate_presence_of(:identifier) }
    it { is_expected.to validate_presence_of(:display_name) }
    it { is_expected.to validate_uniqueness_of(:identifier) }
  end

  describe ".email_lookup_index" do
    it "indexes by primary and alternate emails" do
      ml = create(:mailing_list, email: "pgsql-hackers@lists.postgresql.org",
                                 alternate_emails: ["pgsql-hackers@postgresql.org"])
      index = described_class.email_lookup_index
      expect(index["pgsql-hackers@lists.postgresql.org"]).to eq(ml)
      expect(index["pgsql-hackers@postgresql.org"]).to eq(ml)
    end
  end

  describe "associations" do
    it { is_expected.to have_many(:message_mailing_lists) }
    it { is_expected.to have_many(:messages).through(:message_mailing_lists) }
    it { is_expected.to have_many(:topic_mailing_lists) }
    it { is_expected.to have_many(:topics).through(:topic_mailing_lists) }
  end
end
