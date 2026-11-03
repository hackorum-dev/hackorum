require "rails_helper"

RSpec.describe CommitImport::TrailerParser do
  def parse_fixture(name)
    text = File.read(Rails.root.join("spec/fixtures/commit_import/#{name}"))
    subject, body = text.split("\n", 2)
    described_class.new(subject: subject, body: body).parse
  end

  def parse(subject:, body:)
    described_class.new(subject: subject, body: body).parse
  end

  describe "people" do
    it "maps trailer keys to roles" do
      people = parse_fixture("modern_commit.txt").people
      by_role = people.group_by(&:role)

      expect(by_role["reviewer"].map(&:name)).to eq([ "Jane Reviewer" ])
      expect(by_role["reported_by"].map(&:name)).to eq([ "Bob Reporter" ])
      expect(by_role["co_author"].map(&:name)).to eq([ "Carol Coder" ])
      expect(by_role["author"].map(&:name)).to eq([ "Dan Dev" ])
      expect(by_role["tested_by"].map(&:name)).to eq([ "Tina Tester" ])
    end

    it "extracts email addresses lowercased" do
      person = parse_fixture("modern_commit.txt").people.find { |p| p.role == "reviewer" }
      expect(person.email).to eq("jane@example.com")
    end

    it "ignores trailer keys that are not people" do
      roles = parse_fixture("modern_commit.txt").people.map(&:role)
      expect(roles).not_to include("backpatch_through", "discussion")
    end

    it "splits multiple people in one trailer" do
      result = parse(subject: "x", body: "Reviewed-by: A One <a@x>, B Two <b@y>\n")
      expect(result.people.map(&:name)).to eq([ "A One", "B Two" ])
      expect(result.people.map(&:email)).to eq([ "a@x", "b@y" ])
    end

    it "does not split on commas inside angle brackets" do
      result = parse(subject: "x", body: "Reviewed-by: Lastname, Firstname <a@x>\n")
      expect(result.people.size).to eq(1)
    end

    it "does not merge two bare names into one composite name" do
      result = parse(subject: "x", body: "Reviewed-by: Robert Haas, Tom Lane\n")
      expect(result.people.map(&:name)).to eq([ "Robert Haas", "Tom Lane" ])
      expect(result.people.map(&:email)).to eq([ nil, nil ])
    end

    it "keeps a leading bare email as its own person instead of merging it" do
      result = parse(subject: "x", body: "Reviewed-by: a@x, B Two <b@y>\n")
      expect(result.people.map(&:name)).to eq([ nil, "B Two" ])
      expect(result.people.map(&:email)).to eq([ "a@x", "b@y" ])
    end

    it "keeps a leading full name separate rather than absorbing it" do
      result = parse(subject: "x", body: "Reviewed-by: Solo Name, B Two <b@y>\n")
      expect(result.people.map(&:name)).to eq([ "Solo Name", "B Two" ])
      expect(result.people.map(&:email)).to eq([ nil, "b@y" ])
    end

    it "splits three people in one trailer" do
      result = parse(subject: "x", body: "Reviewed-by: A <a@x>, B <b@y>, C <c@z>\n")
      expect(result.people.map(&:name)).to eq([ "A", "B", "C" ])
      expect(result.people.map(&:email)).to eq([ "a@x", "b@y", "c@z" ])
    end

    it "ignores a trailing comma without a phantom person" do
      result = parse(subject: "x", body: "Reviewed-by: A One <a@x>,\n")
      expect(result.people.map(&:name)).to eq([ "A One" ])
    end

    it "splits a multi-word surname in Last, First form (known limitation, see comment)" do
      result = parse(subject: "x", body: "Reviewed-by: van Rossum, Guido <g@x>\n")
      expect(result.people.map(&:name)).to eq([ "van Rossum", "Guido" ])
      expect(result.people.map(&:email)).to eq([ nil, "g@x" ])
    end

    it "maps unusual trailer-key casing to the same role" do
      body = "REVIEWED-BY: A <a@x>\nReViEwEd-bY: B <b@y>\n"
      expect(parse(subject: "x", body: body).people.map(&:role)).to eq([ "reviewer", "reviewer" ])
    end

    it "parses trailers and wrapped continuations with CRLF line endings" do
      body = "Reviewed-by: Tom Lane <tgl@sss.pgh.pa.us>,\r\n    Andres Freund <andres@anarazel.de>\r\n"
      people = parse(subject: "x", body: body).people
      expect(people.map(&:name)).to eq([ "Tom Lane", "Andres Freund" ])
    end

    it "does not crash on a fully indented body with no trailer ever established" do
      body = "    line one\r\n    line two\r\n"
      expect(parse(subject: "x", body: body).people).to eq([])
    end

    it "joins a trailer wrapped onto an indented continuation line" do
      people = parse_fixture("wrapped_trailers.txt").people.select { |p| p.role == "reviewer" }
      expect(people.map(&:name)).to eq([ "Tom Lane", "Andres Freund" ])
    end

    it "does not treat an indented prose line as a continuation" do
      body = "Some prose here.\n    indented prose, not a trailer\n\nReviewed-by: A <a@x>\n"
      expect(parse(subject: "x", body: body).people.map(&:name)).to eq([ "A" ])
    end

    it "handles a bare email with no display name" do
      result = parse(subject: "x", body: "Reviewed-by: a@x\n")
      expect(result.people.first.email).to eq("a@x")
      expect(result.people.first.name).to be_nil
    end

    it "ignores a note after the email" do
      result = parse(subject: "x", body: "Author: Andrey Borodin <x4mmm@yandex-team.ru> (in absentia)\n")
      expect(result.people.map(&:name)).to eq([ "Andrey Borodin" ])
      expect(result.people.map(&:email)).to eq([ "x4mmm@yandex-team.ru" ])
    end

    it "does not split on commas inside a note" do
      body = "Reviewed-by: Tom Lane <tgl@x> (concept, not the code), Andres Freund <a@y>\n"
      result = parse(subject: "x", body: body)
      expect(result.people.map(&:name)).to eq([ "Tom Lane", "Andres Freund" ])
      expect(result.people.map(&:email)).to eq([ "tgl@x", "a@y" ])
    end

    it "still splits when a paren is never closed" do
      body = "Reviewed-by: Sergey Dudoladov (mysterious, Tom Lane <tgl@x>\n"
      result = parse(subject: "x", body: body)
      expect(result.people.map(&:email)).to eq([ nil, "tgl@x" ])
    end

    it "ignores a note around a bare name" do
      body = "Reviewed-by: Tom Lane (offlist), (in an earlier version) Dilip Kumar\n"
      result = parse(subject: "x", body: body)
      expect(result.people.map(&:name)).to eq([ "Tom Lane", "Dilip Kumar" ])
    end

    it "takes an email in parens" do
      body = "Author: Sho Kato (<kato-sho@fujitsu.com>), suyu.cmj (mengjuan.cmj@alibaba-inc.com)\n"
      result = parse(subject: "x", body: body)
      expect(result.people.map(&:name)).to eq([ "Sho Kato", "suyu.cmj" ])
      expect(result.people.map(&:email)).to eq([ "kato-sho@fujitsu.com", "mengjuan.cmj@alibaba-inc.com" ])
    end

    it "does not credit someone named inside a note" do
      body = "Reported-by: iMSA (via Jehan-Guillaume de Rorthais <jgdr@dalibo.com>)\n"
      result = parse(subject: "x", body: body)
      expect(result.people.map(&:name)).to eq([ "iMSA" ])
      expect(result.people.map(&:email)).to eq([ nil ])
    end

    it "takes an unclosed or doubled bracket email" do
      body = "Reviewed-by: Andres Freund <andres@anarazel.de\nTested-by: David Rowley <<dgr@x>> (earlier version)\n"
      result = parse(subject: "x", body: body)
      expect(result.people.map(&:name)).to eq([ "Andres Freund", "David Rowley" ])
      expect(result.people.map(&:email)).to eq([ "andres@anarazel.de", "dgr@x" ])
    end

    it "keeps a quoted name with a comma together and drops the quotes" do
      body = %(Author: "Tang, Haiying" <tanghy@x>, "A1ex" <a@y>\n)
      result = parse(subject: "x", body: body)
      expect(result.people.map(&:name)).to eq([ "Tang, Haiying", "A1ex" ])
      expect(result.people.map(&:email)).to eq([ "tanghy@x", "a@y" ])
    end

    it "splits people joined with and" do
      body = "Reviewed-by: Amit Kapila and Robert Haas\nReported-by: Yuhang Wu <y@x> and Zhenpeng Lin\n"
      result = parse(subject: "x", body: body)
      expect(result.people.map(&:name)).to eq([ "Amit Kapila", "Robert Haas", "Yuhang Wu", "Zhenpeng Lin" ])
      expect(result.people.map(&:email)).to eq([ nil, nil, "y@x", nil ])
    end

    it "does not split on and inside a note" do
      body = "Reported-by: Andrew Dunstan (found by Simon and Tom)\n"
      expect(parse(subject: "x", body: body).people.map(&:name)).to eq([ "Andrew Dunstan" ])
    end

    it "handles a bare name with no email" do
      result = parse(subject: "x", body: "Reported-by: buildfarm member koel\n")
      expect(result.people.first.name).to eq("buildfarm member koel")
      expect(result.people.first.email).to be_nil
    end
  end

  describe "message_ids" do
    {
      "https://postgr.es/m/abc@x" => "abc@x",
      "https://postgr.es/message-id/abc@x" => "abc@x",
      "https://www.postgresql.org/message-id/abc@x" => "abc@x",
      "https://www.postgresql.org/message-id/flat/abc@x" => "abc@x",
      "http://postgre.es/m/abc@x" => "abc@x",
      "see https://postgr.es/m/abc@x." => "abc@x",
      "https://postgr.es/m/abc@x#abc@x" => "abc@x",
      "https://postgr.es/m/abc@x/" => "abc@x",
      "https://postgr.es/m//abc@x" => "abc@x"
    }.each do |url, expected|
      it "extracts #{expected} from #{url}" do
        expect(parse(subject: "x", body: "Discussion: #{url}\n").message_ids).to eq([ expected ])
      end
    end

    it "deduplicates repeated ids" do
      body = "Discussion: https://postgr.es/m/abc@x\nDiscussion: https://postgr.es/m/abc@x\n"
      expect(parse(subject: "x", body: body).message_ids).to eq([ "abc@x" ])
    end

    it "drops attachment links, which are not message ids" do
      body = "Discussion: https://postgr.es/m/abc@x\n" \
             "Discussion: https://www.postgresql.org/message-id/attachment/133167/0016-blank.patch\n"
      expect(parse(subject: "x", body: body).message_ids).to eq([ "abc@x" ])
    end

    it "keeps percent-encoded ids raw for the caller to decode" do
      expect(parse_fixture("wrapped_trailers.txt").message_ids).to eq([ "CAD21AoA%3Dabc%40mail.gmail.com" ])
    end
  end

  describe "nil input" do
    it "returns empty results without raising" do
      result = described_class.new(subject: nil, body: nil).parse
      expect(result.people).to eq([])
      expect(result.message_ids).to eq([])
      expect(result.cherry_picked_from).to be_nil
    end
  end

  describe "cherry_picked_from" do
    it "extracts the cherry-pick source" do
      result = parse(subject: "Some backport", body: "(cherry picked from commit abcdef1234567890)")
      expect(result.cherry_picked_from).to eq("abcdef1234567890")
    end

    it "ignores a plain fix reference" do
      result = parse(subject: "Repair oversight", body: "This is the fix for commit deadbeefcafe1234.")
      expect(result.cherry_picked_from).to be_nil
    end
  end
end
