# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonMerge do
  it "resolves the target person while it still exists" do
    target = create(:person)
    merge = create(:person_merge, target_person_id: target.id)

    expect(merge.target_person).to eq(target)
  end

  it "survives the target person being deleted" do
    target = create(:person)
    merge = create(:person_merge, target_person_id: target.id)

    target.destroy!

    expect(merge.reload.target_name).to eq("Kept Name")
    expect(merge.target_person).to be_nil
  end

  it "defaults source_emails to an empty array" do
    merge = PersonMerge.create!(
      performed_by: create(:user),
      source_person_id: create(:person).id,
      target_person_id: create(:person).id
    )

    expect(merge.source_emails).to eq([])
  end
end
