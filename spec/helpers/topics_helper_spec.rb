require "rails_helper"

RSpec.describe TopicsHelper, type: :helper do
  it "labels month ranges" do
    expect(helper.month_range_label(Date.new(2024, 4, 6), Date.new(2024, 5, 26))).to eq("Apr - May 2024")
    expect(helper.month_range_label(Date.new(2026, 6, 30), Date.new(2026, 6, 1))).to eq("Jun 2026")
    expect(helper.month_range_label(Date.new(2025, 12, 14), Date.new(2026, 1, 5))).to eq("Dec 2025 - Jan 2026")
  end

  it "shortens name lists" do
    expect(helper.short_name_list(%w[Korotkov Koval Wang Guo])).to eq("Korotkov, Koval +2")
    expect(helper.short_name_list(%w[Korotkov])).to eq("Korotkov")
  end

  describe "participant without an alias" do
    let(:person) { create(:person) }
    let(:participant) { { alias: nil, person: person, message_count: 3 } }

    context "when the person has other aliases" do
      before do
        create(:alias, person: person, name: "Rare Name", sender_count: 1)
        create(:alias, person: person, name: "Main Name", sender_count: 9)
      end

      it "avatar list uses the busiest alias" do
        html = helper.avatar_list_html(participants: [ participant ], total_participants: 1)
        expect(html).to include('alt="Main Name"')
      end

      it "participant row uses the busiest alias" do
        html = helper.participant_row_html(participant: participant)
        expect(html).to include("Main Name")
      end
    end

    context "when the person has no aliases" do
      it "avatar list skips the participant" do
        html = helper.avatar_list_html(participants: [ participant ], total_participants: 1)
        expect(html).not_to include("participant-avatar-link")
      end

      it "participant row renders nothing" do
        expect(helper.participant_row_html(participant: participant)).to be_nil
      end
    end
  end
end
