require "rails_helper"

RSpec.describe "API v1 /mailing_lists", type: :request do
  def data
    JSON.parse(response.body)["data"]
  end

  it "lists every list by display name without a token" do
    create(:mailing_list, identifier: "pgsql-hackers", display_name: "pgsql-hackers")
    create(:mailing_list, identifier: "pgsql-bugs", display_name: "pgsql-bugs", hidden_by_default: true,
           description: "Bug reports", post_address: "post@example.org", alternate_emails: [ "alt@example.org" ])

    get "/api/v1/mailing_lists"

    expect(response).to have_http_status(:ok)
    expect(response.headers["RateLimit-Limit"]).to be_present
    expect(JSON.parse(response.body)["next_cursor"]).to be_nil
    expect(data).to eq([
      { "identifier" => "pgsql-bugs", "display_name" => "pgsql-bugs", "hidden_by_default" => true },
      { "identifier" => "pgsql-hackers", "display_name" => "pgsql-hackers", "hidden_by_default" => false }
    ])
  end

  it "answers an empty list" do
    get "/api/v1/mailing_lists"

    expect(JSON.parse(response.body)).to eq("data" => [], "next_cursor" => nil)
  end

  it "runs the same queries for one row and for three" do
    create(:mailing_list)
    one = captured_queries { get "/api/v1/mailing_lists" }
    create_list(:mailing_list, 2)
    three = captured_queries { get "/api/v1/mailing_lists" }

    expect(data.size).to eq(3)
    expect(three.size).to eq(one.size)
  end

  it "does not write" do
    create(:mailing_list)

    queries = captured_queries { get "/api/v1/mailing_lists" }

    expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
  end
end
