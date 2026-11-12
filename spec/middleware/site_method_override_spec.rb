require "rails_helper"

RSpec.describe SiteMethodOverride do
  let(:seen) { {} }
  let(:app) do
    described_class.new(lambda do |env|
      seen[:method] = env["REQUEST_METHOD"]
      seen[:parsed] = env.key?("rack.request.form_hash")
      [ 200, {}, [] ]
    end)
  end

  def call(path, **options)
    app.call(Rack::MockRequest.env_for(path, method: "POST", **options))
    seen
  end

  it "is the one in the stack" do
    names = Rails.application.middleware.map(&:name)

    expect(names).to include("SiteMethodOverride")
    expect(names).not_to include("Rack::MethodOverride")
    expect(names.index("SiteMethodOverride")).to be < names.index("ActionDispatch::ShowExceptions")
  end

  it "overrides the method of a site form, by field and by header" do
    expect(call("/notes/1", params: { _method: "delete" })).to eq(method: "DELETE", parsed: true)
    expect(call("/notes/1", "HTTP_X_HTTP_METHOD_OVERRIDE" => "PATCH")).to include(method: "PATCH")
    expect(call("/api/v10/x", params: { _method: "delete" })).to include(method: "DELETE")
  end

  it "leaves the method of an API request and does not parse its body" do
    %w[/api/v1 /api/v1/drafts/1 /api/v1.json].each do |path|
      expect(call(path, params: { _method: "delete" })).to eq(method: "POST", parsed: false), path
      expect(call(path, "HTTP_X_HTTP_METHOD_OVERRIDE" => "DELETE")).to eq(method: "POST", parsed: false), path
    end
  end
end
