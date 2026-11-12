require "rails_helper"

RSpec.describe "Settings::ApiTokens", type: :request do
  let(:user) { create(:user) }

  it "redirects guests to sign in" do
    get settings_api_tokens_path
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "creates a token and shows it once" do
      expect {
        post settings_api_tokens_path, params: { name: "laptop", expires_in: "30" }
      }.to change { user.api_tokens.count }.by(1)

      expect(response).to have_http_status(:ok)
      raw = response.body[/hko_[A-Za-z0-9_-]+/]
      expect(raw).to be_present
      expect(response.headers["Cache-Control"]).to include("no-store")

      token = user.api_tokens.last
      expect(token.name).to eq("laptop")
      expect(token.expires_at).to be_within(1.minute).of(30.days.from_now)
      expect(ApiToken.authenticate(raw)).to eq(token)

      get settings_api_tokens_path
      expect(response.body).to include("laptop")
      expect(response.body).not_to include(raw)
    end

    it "creates a token that works on the API" do
      post settings_api_tokens_path, params: { name: "laptop" }
      raw = response.body[/hko_[A-Za-z0-9_-]+/]

      get "/api/v1/me", headers: { "Authorization" => "Bearer #{raw}" }

      expect(response).to have_http_status(:ok)
    end

    it "creates a token without expiry by default" do
      post settings_api_tokens_path, params: { name: "forever" }
      expect(user.api_tokens.last.expires_at).to be_nil
    end

    it "refuses a blank name" do
      expect {
        post settings_api_tokens_path, params: { name: " " }
      }.not_to change(ApiToken, :count)
      expect(response).to redirect_to(settings_api_tokens_path)
    end

    it "refuses control characters in the name" do
      [ "a\0b", "a\r\nb" ].each do |name|
        expect {
          post settings_api_tokens_path, params: { name: name }
        }.not_to change(ApiToken, :count)
        expect(response).to redirect_to(settings_api_tokens_path)
        expect(flash[:alert]).to be_present
      end
    end

    it "refuses an expiry that is not on offer" do
      expect {
        post settings_api_tokens_path, params: { name: "laptop", expires_in: "1" }
      }.not_to change(ApiToken, :count)
      expect(response).to redirect_to(settings_api_tokens_path)
      expect(flash[:alert]).to be_present
    end

    it "counts and inserts under a lock on the user" do
      locked = false
      allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        original.call(*args) do
          locked = true
          block.call
        ensure
          locked = false
        end
      end
      allow(ApiToken).to receive(:issue!).and_wrap_original do |original, **args|
        expect(locked).to be(true)
        original.call(**args)
      end

      post settings_api_tokens_path, params: { name: "laptop" }

      expect(response).to have_http_status(:ok)
      expect(ApiToken).to have_received(:issue!)
    end

    it "shows the new token in a labelled read-only field" do
      post settings_api_tokens_path, params: { name: "laptop" }

      page = Nokogiri::HTML(response.body)
      input = page.at_css("input.api-token-value")
      expect(input["readonly"]).to be_present
      expect(input["value"]).to match(/\Ahko_[A-Za-z0-9_-]+\z/)
      expect(page.at_css("label[for='#{input['id']}']").text).to eq("New token")
    end

    it "escapes the token name in the list" do
      ApiToken.issue!(user: user, name: "<script>alert(1)</script>")

      get settings_api_tokens_path

      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(response.body).not_to include("<script>alert(1)")
    end

    it "disables the create button on submit" do
      get settings_api_tokens_path

      form = Nokogiri::HTML(response.body).at_css("form[action='#{settings_api_tokens_path}'][method='post']")
      expect(form["onsubmit"]).to include("disabled = true")
      expect(form["data-turbo"]).to eq("false")
    end

    it "links the API description and sets the page title" do
      get settings_api_tokens_path

      page = Nokogiri::HTML(response.body)
      expect(page.at_css("a[href='/api/v1/openapi.yaml']").text).to eq("API description (OpenAPI)")
      expect(page.at_css("a[href='/help/api']").text).to eq("API help")
      expect(page.at_css("title").text).to include("API tokens")
    end

    it "refuses more than the maximum" do
      ApiToken::MAX_PER_USER.times { |i| ApiToken.issue!(user: user, name: "t#{i}") }

      expect {
        post settings_api_tokens_path, params: { name: "one more" }
      }.not_to change(ApiToken, :count)
      expect(response).to redirect_to(settings_api_tokens_path)
    end

    it "lists only own, unrevoked tokens" do
      ApiToken.issue!(user: user, name: "mine-live")
      ApiToken.issue!(user: user, name: "mine-revoked").first.revoke!
      ApiToken.issue!(user: create(:user), name: "someone-else")

      get settings_api_tokens_path

      expect(response.body).to include("mine-live")
      expect(response.body).not_to include("mine-revoked")
      expect(response.body).not_to include("someone-else")
    end

    it "revokes a token" do
      token, raw = ApiToken.issue!(user: user, name: "laptop")

      delete settings_api_token_path(token)

      expect(response).to redirect_to(settings_api_tokens_path)
      expect(ApiToken.authenticate(raw)).to be_nil
    end

    it "does not revoke a token twice" do
      token, = ApiToken.issue!(user: user, name: "laptop")
      token.update_columns(revoked_at: 1.day.ago)

      expect {
        delete settings_api_token_path(token)
      }.not_to change { token.reload.revoked_at }
      expect(response).to have_http_status(:not_found)
    end

    it "does not revoke someone else's token" do
      token, raw = ApiToken.issue!(user: create(:user), name: "theirs")

      delete settings_api_token_path(token)

      expect(response).to have_http_status(:not_found)
      expect(ApiToken.authenticate(raw)).to eq(token)
    end
  end
end
