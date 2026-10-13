require "rails_helper"

RSpec.describe "Admin::GlobalTags", type: :request do
  let(:admin) { create(:user, admin: true) }

  before { sign_in_as(admin) }

  def use_tag(name)
    note = Note.create!(topic: create(:topic), author: admin, body: "@global ##{name}", global: true)
    note.note_tags.create!(tag: name)
  end

  it "rejects non-admins" do
    sign_in_as(create(:user))
    get admin_global_tags_path
    expect(response).to have_http_status(:found)
  end

  it "lists tags with counts" do
    create(:global_tag, name: "needs-review", description: "Waiting for review")
    use_tag("needs-review")

    get admin_global_tags_path
    expect(response.body).to include("needs-review", "Waiting for review")
  end

  it "creates a tag" do
    post admin_global_tags_path, params: { global_tag: { name: "Bugfix", description: "d" } }
    tag = GlobalTag.find_by(name: "bugfix")
    expect(tag.created_by).to eq(admin)
    expect(response).to redirect_to(admin_global_tags_path)
  end

  it "re-renders on invalid name" do
    post admin_global_tags_path, params: { global_tag: { name: "bad name" } }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "updates only the description" do
    tag = create(:global_tag, name: "keep")
    patch admin_global_tag_path(tag), params: { global_tag: { name: "changed", description: "new" } }
    tag.reload
    expect(tag.name).to eq("keep")
    expect(tag.description).to eq("new")
  end

  it "retires and unretires" do
    tag = create(:global_tag)
    post retire_admin_global_tag_path(tag)
    expect(tag.reload.retired_at).to be_present
    post unretire_admin_global_tag_path(tag)
    expect(tag.reload.retired_at).to be_nil
  end

  it "deletes only unused tags" do
    used = create(:global_tag, name: "used")
    unused = create(:global_tag, name: "unused")
    use_tag("used")

    delete admin_global_tag_path(used)
    expect(GlobalTag.exists?(used.id)).to be(true)
    expect(flash[:alert]).to be_present

    delete admin_global_tag_path(unused)
    expect(GlobalTag.exists?(unused.id)).to be(false)
  end
end
