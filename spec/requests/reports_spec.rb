require "rails_helper"

RSpec.describe "Reports", type: :request do
  let!(:hidden_list) { create(:mailing_list, hidden_by_default: true) }
  let!(:shown_list) { create(:mailing_list) }

  before { Rails.cache.clear }

  def topic_on(list, title)
    create(:topic, title: title, created_at: Time.current).tap do |t|
      msg = create(:message, topic: t, created_at: Time.current)
      MessageMailingList.create!(message: msg, mailing_list: list)
    end
  end

  it "leaves hidden-list threads out of the current week" do
    topic_on(shown_list, "Planner discussion")
    topic_on(hidden_list, "pgsql: commit notice")
    today = Date.current

    get weekly_report_path(year: today.cwyear, week: today.cweek)

    expect(response).to have_http_status(:success)
    expect(response.body).to include("Planner discussion")
    expect(response.body).not_to include("pgsql: commit notice")
  end
end
