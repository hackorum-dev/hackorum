require 'rails_helper'

RSpec.describe "topics routes", type: :routing do
  describe "removed endpoints" do
    it "no longer routes user_state_frame" do
      expect(get: "/topics/user_state_frame").not_to route_to(controller: "topics", action: "user_state_frame")
    end

    it "no longer routes user_state" do
      expect(post: "/topics/user_state").not_to be_routable
    end

    it "no longer routes aware_bulk" do
      expect(post: "/topics/aware_bulk").not_to be_routable
    end

    it "no longer routes aware_all" do
      expect(post: "/topics/aware_all").not_to be_routable
    end

    it "still routes per-topic aware" do
      expect(post: "/topics/1/aware").to be_routable
    end
  end

  describe "row states" do
    it "routes the collection endpoint" do
      expect(get: "/topics/row_states").to route_to(controller: "topics", action: "row_states")
    end
  end
end
