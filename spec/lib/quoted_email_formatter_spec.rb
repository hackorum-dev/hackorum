# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuotedEmailFormatter do
  describe "#reference_map" do
    it "collects single and multi-line reference definitions" do
      body = <<~BODY
        [1] Bertrand's hide everything idea -
        https://www.postgresql.org/message-id/Z3fimYj0fbkLmWJb%40ip-10-97-1-34.eu-west-3.compute.internal

        [2]: https://example.com/ref2
      BODY

      formatter = described_class.new(body)

      expect(formatter.reference_map["1"]).to eq("Bertrand's hide everything idea - https://www.postgresql.org/message-id/Z3fimYj0fbkLmWJb%40ip-10-97-1-34.eu-west-3.compute.internal")
      expect(formatter.reference_map["2"]).to eq("https://example.com/ref2")
    end

    it "collects definitions when the URL is on the next non-empty line" do
      body = <<~BODY
        References:
        [1]
        https://github.com/postgres/postgres/blob/master/src/backend/access/transam/multixact.c#L2925-L2948
      BODY

      formatter = described_class.new(body)

      expect(formatter.reference_map["1"]).to include("multixact.c#L2925-L2948")
    end

    it "ignores definitions inside quoted text" do
      body = <<~BODY
        > [9]: https://example.com/old

        [1]: https://example.com/fresh
      BODY

      formatter = described_class.new(body)

      expect(formatter.reference_map.key?("9")).to be_falsey
      expect(formatter.reference_map["1"]).to eq("https://example.com/fresh")
    end
  end

  describe "#to_html" do
    it "renders jammed inline references with hover text and keeps URLs clickable" do
      body = <<~BODY
        There are several earlier discussions[2][3]

        [2]: https://example.com/ref2
        [3] explanation line
            continues here
      BODY

      html = described_class.new(body).to_html

      expect(html.scan(/inline-reference/).size).to eq(2)
      expect(html).to include(%q(href="https://example.com/ref2"))
      expect(html).to include(%q(explanation line continues here))
    end

    it "does not link inline references inside quoted text" do
      body = <<~BODY
        > This references [2] but comes from earlier thread

        Direct ref [1] should link

        [1]: https://example.com/ref1
        [2]: https://example.com/ref2
      BODY

      html = described_class.new(body).to_html

      expect(html).to include(%q(inline-reference">[1]))
      expect(html).not_to include(%q(inline-reference">[2]))
    end

    it "rewrites known message-id links to local resolver" do
      body = <<~BODY
        See https://www.postgresql.org/message-id/flat/abcd%40example.com and also https://postgr.es/m/efgh%40example.com
      BODY

      html = described_class.new(body).to_html

      resolver_path_one = Rails.application.routes.url_helpers.message_by_id_path(message_id: "abcd@example.com")
      resolver_path_two = Rails.application.routes.url_helpers.message_by_id_path(message_id: "efgh@example.com")

      expect(html).to include(resolver_path_one)
      expect(html).to include(resolver_path_two)
    end

    it "preserves plus signs in message-id rewriting" do
      body = <<~BODY
        See https://www.postgresql.org/message-id/CAJ7c6TPDOYBYrnCAeyndkBktO0WG2xSdYduTF0nxq+vfkmTF5Q@mail.gmail.com
      BODY

      html = described_class.new(body).to_html

      resolver_path = Rails.application.routes.url_helpers.message_by_id_path(message_id: "CAJ7c6TPDOYBYrnCAeyndkBktO0WG2xSdYduTF0nxq+vfkmTF5Q@mail.gmail.com")

      expect(html).to include(resolver_path)
    end
  end
end
