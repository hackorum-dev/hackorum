require "rails_helper"

RSpec.describe GlobalTag, type: :model do
  let(:author) { create(:user, username: "alice") }
  let(:topic) { create(:topic) }

  def global_note_with(tag, topic: self.topic, deleted: false)
    note = Note.create!(topic:, author:, body: "@global ##{tag}", global: true,
                        deleted_at: (Time.current if deleted))
    note.note_tags.create!(tag:)
    note
  end

  it "normalizes and validates the name" do
    expect(create(:global_tag, name: " Needs-Review ").name).to eq("needs-review")
    expect(build(:global_tag, name: "bad tag")).not_to be_valid
  end

  it "keeps the name readonly" do
    tag = create(:global_tag, name: "a")
    expect { tag.update!(name: "b") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(tag.reload.name).to eq("a")
  end

  it "retires and unretires" do
    tag = create(:global_tag)
    tag.retire!
    expect(described_class.retired).to include(tag)
    expect(described_class.active).not_to include(tag)
    tag.unretire!
    expect(described_class.active).to include(tag)
  end

  it "refuses to destroy a used tag" do
    tag = create(:global_tag, name: "used")
    global_note_with("used")

    expect(tag.destroy).to be(false)
    expect(tag.errors[:base]).to be_present
    expect(described_class.exists?(tag.id)).to be(true)
  end

  it "destroys an unused tag" do
    tag = create(:global_tag, name: "unused")
    global_note_with("unused", deleted: true)

    expect(tag.destroy).to be_truthy
  end

  it "counts distinct topics per tag over active global notes" do
    other_topic = create(:topic)
    global_note_with("a")
    global_note_with("a")
    global_note_with("a", topic: other_topic)
    global_note_with("b", deleted: true)
    private_note = Note.create!(topic:, author:, body: "#b")
    private_note.note_tags.create!(tag: "b")

    expect(described_class.usage_counts).to eq("a" => 2)
  end
end
