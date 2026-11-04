# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Help", type: :request do
  describe "GET /help" do
    it "returns the help index page" do
      get help_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Help")
      expect(response.body).to include("Advanced Search Guide")
    end
  end

  describe "GET /help/:slug" do
    it "renders the privacy policy with the anchors other pages link to" do
      get help_path("privacy")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="deleting-your-account"', 'id="recipients"', 'href="#recipients"')
    end

    context "with valid slug" do
      it "returns the help page" do
        get help_path("search")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Advanced Search Guide")
      end

      it "renders markdown content as HTML" do
        get help_path("search")

        expect(response.body).to include("<h1")
        expect(response.body).to include("<code>")
        expect(response.body).to include("<pre>")
      end
    end

    context "with invalid slug" do
      it "returns 404" do
        get help_path("nonexistent-page")

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
