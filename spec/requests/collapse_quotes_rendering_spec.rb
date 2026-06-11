# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Collapse quotes rendering", type: :request do
  let(:body_with_inline_quote) do
    <<~BODY
      On Mon, Jun 1, 2026 Alice wrote:
      > inline quoted point

      Reply to the inline quote.
    BODY
  end

  let!(:topic) { create(:topic) }
  let!(:message) { create(:message, topic: topic, body: body_with_inline_quote) }

  context "when signed out" do
    it "renders inline quotes uncollapsed" do
      get topic_path(topic)

      expect(response).to have_http_status(:success)
      expect(response.body).not_to include("quoted-block")
      expect(response.body).to include("<blockquote>")
    end
  end

  context "when signed in with collapse_quotes off (default)" do
    it "renders inline quotes uncollapsed" do
      sign_in_as(create(:user))

      get topic_path(topic)

      expect(response).to have_http_status(:success)
      expect(response.body).not_to include("quoted-block")
    end
  end

  context "when signed in with collapse_quotes on" do
    it "wraps quoted text in a collapsible block" do
      sign_in_as(create(:user, collapse_quotes: true))

      get topic_path(topic)

      expect(response).to have_http_status(:success)
      expect(response.body).to include('<details class="quoted-block">')
      expect(response.body).to include("<summary>Show quoted text</summary>")
      expect(response.body).to include("Reply to the inline quote.")
    end
  end
end
