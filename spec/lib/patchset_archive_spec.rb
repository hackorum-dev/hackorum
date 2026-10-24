require "rails_helper"
require "zlib"
require "rubygems/package"

RSpec.describe PatchsetArchive do
  let(:creator) { create(:alias) }
  let(:topic)   { create(:topic, creator: creator) }
  let!(:first_message) do
    create(:message, topic: topic, sender: creator,
           message_id: "first@example.com", created_at: 2.days.ago)
  end
  let!(:patch_message) do
    create(:message, topic: topic, sender: creator, created_at: 1.hour.ago)
  end
  let!(:patch1) do
    create(:attachment, :patch_file, message: patch_message,
           file_name: "0001-foo.patch")
  end
  let!(:patch2) do
    create(:attachment, :patch_file, message: patch_message,
           file_name: "0002-bar.patch")
  end

  describe ".build" do
    def number_for(topic, message)
      topic.messages.order(:created_at).pluck(:id).index(message.id).to_i + 1
    end

    subject(:result) { described_class.build(message: patch_message, attachment_number: number_for(topic, patch_message)) }

    it "returns a tar.gz blob and a filename" do
      expect(result[:data]).to be_a(String)
      expect(result[:filename]).to eq(
        "topic-#{topic.id}-msg2-patchset.tar.gz"
      )
    end

    it "includes all patch attachments and metadata" do
      extracted = {}
      io = StringIO.new(result[:data])
      Zlib::GzipReader.wrap(io) do |gz|
        Gem::Package::TarReader.new(gz) do |tar|
          tar.each { |entry| extracted[entry.full_name] = entry.read }
        end
      end

      expect(extracted).to have_key("hackorum.json")
      expect(extracted).to have_key("0001-foo.patch")
      expect(extracted).to have_key("0002-bar.patch")

      metadata = JSON.parse(extracted["hackorum.json"])
      expect(metadata["topic_id"]).to eq(topic.id)
      expect(metadata["upstream_url"]).to include("first%40example.com")
    end

    it "strips paths, truncates long names and dedupes entries" do
      create(:attachment, :patch_file, message: patch_message, file_name: "../../evil/.git/config.patch")
      create(:attachment, :patch_file, message: patch_message, file_name: "0001-foo.patch")
      create(:attachment, :patch_file, message: patch_message, file_name: "#{'x' * 150}.patch")

      names = []
      Zlib::GzipReader.wrap(StringIO.new(result[:data])) do |gz|
        Gem::Package::TarReader.new(gz) { |tar| tar.each { |e| names << e.full_name } }
      end

      expect(names).to include("config.patch", "0001-foo.patch", "1-0001-foo.patch")
      expect(names).to all(satisfy { |n| !n.include?("/") && n.bytesize <= 100 })
      expect(names.uniq.size).to eq(names.size)
    end

    it "returns nil when the message has no patch attachments" do
      bare = create(:message, topic: topic, sender: creator)
      expect(described_class.build(message: bare, attachment_number: 1)).to be_nil
    end

    context "with multiple patch-submission messages in the topic" do
      let!(:older_patch_message) do
        create(:message, topic: topic, sender: creator, created_at: 6.hours.ago)
      end
      let!(:older_patch) do
        create(:attachment, :patch_file, message: older_patch_message,
               file_name: "0001-older.patch")
      end

      it "numbers patch-submission messages chronologically" do
        older_result = described_class.build(message: older_patch_message, attachment_number: number_for(topic, older_patch_message))
        latest_result = described_class.build(message: patch_message, attachment_number: number_for(topic, patch_message))

        expect(older_result[:filename]).to eq("topic-#{topic.id}-msg2-patchset.tar.gz")
        expect(latest_result[:filename]).to eq("topic-#{topic.id}-msg3-patchset.tar.gz")
      end
    end
  end
end
