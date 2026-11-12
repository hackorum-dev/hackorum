require "rails_helper"

RSpec.describe Api::V1::BaseController, type: :controller do
  controller(described_class) do
    query_params :plain, paged: true, on: :index

    def index
      rows, cursor = paginate(ApiToken.all, columns: %w[api_tokens.last_used_at api_tokens.id],
                              not_null: [ "api_tokens.last_used_at" ]) { |relation| relation.includes(:user) }
      preloaded = rows.all? { |row| row.association(:user).loaded? }
      if params[:plain]
        render_page(rows.map { |row| { name: row.name, preloaded: preloaded } }, cursor)
      else
        render_page(rows, cursor) { |row| { name: row.name } }
      end
    end
  end

  before do
    user = create(:user)
    [ nil, 2.days.ago, 1.day.ago ].each_with_index do |used, i|
      ApiToken.issue!(user: user, name: "t#{i}").first.update_columns(last_used_at: used)
    end
  end

  it "renders already serialized hashes without a block" do
    get :index, params: { plain: 1, limit: 1 }

    body = JSON.parse(response.body)
    expect(body["data"]).to eq([ { "name" => "t2", "preloaded" => true } ])
    expect(body["next_cursor"]).to be_a(String)
  end

  it "maps records through the block" do
    get :index, params: { limit: 5 }

    expect(JSON.parse(response.body)).to eq("data" => [ { "name" => "t2" }, { "name" => "t1" } ], "next_cursor" => nil)
  end
end
