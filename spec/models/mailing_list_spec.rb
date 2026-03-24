require "rails_helper"

RSpec.describe MailingList, type: :model do
  describe "validations" do
    subject { build(:mailing_list) }

    it { is_expected.to validate_presence_of(:identifier) }
    it { is_expected.to validate_presence_of(:display_name) }
    it { is_expected.to validate_uniqueness_of(:identifier) }
  end

  describe "associations" do
    it { is_expected.to have_many(:message_mailing_lists) }
    it { is_expected.to have_many(:messages).through(:message_mailing_lists) }
    it { is_expected.to have_many(:topic_mailing_lists) }
    it { is_expected.to have_many(:topics).through(:topic_mailing_lists) }
  end
end
