require "rails_helper"

RSpec.describe "shared/_modal_link", type: :view do
  it "renders a trigger, a dialog and an empty lazy frame" do
    render partial: "shared/modal_link",
           locals: { label: "28 commits", src: "/topics/1/commits_details", frame_id: "topic-commits-modal",
                     title: "Commits and credits", link_class: "sidebar-block-more" }

    doc = Nokogiri::HTML(rendered)
    link = doc.at_css("a.sidebar-block-more")
    expect(link["href"]).to eq("/topics/1/commits_details")
    expect(link["data-action"]).to eq("modal#open")
    dialog = doc.at_css("dialog.modal")
    expect(dialog["data-modal-target"]).to eq("dialog")
    expect(dialog["aria-label"]).to eq("Commits and credits")
    frame = dialog.at_css("turbo-frame#topic-commits-modal")
    expect(frame).to be_present
    expect(frame["src"]).to be_nil
    expect(frame["target"]).to eq("_top")
    expect(frame["data-modal-target"]).to eq("frame")
    expect(doc.at_css("[data-controller=modal]")["data-modal-src-value"]).to eq("/topics/1/commits_details")
  end

  it "renders an optional subtitle" do
    render partial: "shared/modal_link",
           locals: { label: "x", src: "/s", frame_id: "f", title: "Commitfest", subtitle: "2 patches" }

    expect(Nokogiri::HTML(rendered).at_css(".modal-subtitle").text).to eq("2 patches")
  end
end
