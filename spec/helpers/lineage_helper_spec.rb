require "rails_helper"

RSpec.describe LineageHelper, type: :helper do
  let(:ordinals) { { 42 => 7 } }
  let(:sha) { "a" * 40 }

  describe "#lineage_text" do
    it "escapes html" do
      expect(helper.lineage_text("a <b> c", ordinals)).to eq("a &lt;b&gt; c")
    end

    it "links message tokens by ordinal" do
      expect(helper.lineage_text("see [msg:42]", ordinals)).to eq('see <a href="#message-42">#7</a>')
    end

    it "falls back to the id for unknown messages" do
      expect(helper.lineage_text("see [msg:99]", ordinals)).to eq('see <a href="#message-99">#99</a>')
    end

    it "links commit tokens" do
      html = helper.lineage_text("in [commit:#{sha}]", ordinals)
      expect(html).to include(%(href="https://github.com/postgres/postgres/commit/#{sha}"))
      expect(html).to include('target="_blank"')
      expect(html).to include('rel="noopener"')
      expect(html).to include(">aaaaaaaaaa</a>")
    end

    it "is html safe and handles nil" do
      expect(helper.lineage_text("x", ordinals)).to be_html_safe
      expect(helper.lineage_text(nil, ordinals)).to eq("")
    end
  end

  describe "#lineage_plain" do
    it "replaces tokens with plain text" do
      expect(helper.lineage_plain("[msg:42] [msg:99] [commit:#{sha}] <x>", ordinals)).to eq("#7 #99 aaaaaaaaaa <x>")
    end
  end

  describe "#story_chapters" do
    let(:chapters) { double(index_of: nil).tap { |c| allow(c).to receive(:index_of) { |id| { 1 => 0, 2 => 1, 3 => 1, 4 => 2 }[id] } } }

    it "groups by first message ref and inherits for lines without one" do
      lines = [ "intro", "a [msg:1]", "b [msg:2]", "no ref", "c [msg:3]", "d [msg:4] [msg:1]" ]
      expect(helper.story_chapters(lines, chapters)).to eq(
        [ [ 0, [ "intro", "a [msg:1]" ] ], [ 1, [ "b [msg:2]", "no ref", "c [msg:3]" ] ], [ 2, [ "d [msg:4] [msg:1]" ] ] ]
      )
    end

    it "merges lines of a chapter that come back later, in chapter order" do
      lines = [ "b [msg:2]", "a [msg:1]", "c [msg:3]" ]
      expect(helper.story_chapters(lines, chapters)).to eq([ [ 0, [ "a [msg:1]" ] ], [ 1, [ "b [msg:2]", "c [msg:3]" ] ] ])
    end

    it "keeps unknown message refs in the current chapter" do
      expect(helper.story_chapters([ "a [msg:2]", "b [msg:99]" ], chapters)).to eq([ [ 1, [ "a [msg:2]", "b [msg:99]" ] ] ])
    end
  end

  describe "#story_dot_class" do
    it "classifies by commit ref" do
      revert = "b" * 40
      expect(helper.story_dot_class("x [commit:#{sha}]", Set[revert])).to eq("is-commit")
      expect(helper.story_dot_class("x [commit:#{revert}]", Set[revert])).to eq("is-revert")
      expect(helper.story_dot_class("x", Set.new)).to eq("is-talk")
    end
  end

  describe "#lineage_step_words" do
    it "names steps with the parent" do
      expect(helper.lineage_step_words("new_series", nil)).to eq([ "new series", nil, nil ])
      expect(helper.lineage_step_words("minor_revision", 3)).to eq([ "small revision", 3, nil ])
      expect(helper.lineage_step_words("major_rework", 3)).to eq([ "reworked version", 3, nil ])
      expect(helper.lineage_step_words("fix_on_top", 3)).to eq([ "fix on top", 3, nil ])
      expect(helper.lineage_step_words("rebase", 3)).to eq([ "rebase", 3, nil ])
      expect(helper.lineage_step_words("remainder", 3)).to eq([ "rest", 3, "after a partial commit" ])
      expect(helper.lineage_step_words("resend", 3)).to eq([ "resend", 3, nil ])
    end

    it "falls back to the raw kind and drops a missing parent" do
      expect(helper.lineage_step_words("odd_one", 2)).to eq([ "odd one", 2, nil ])
      expect(helper.lineage_step_words("rebase", nil)).to eq([ "rebase", nil, nil ])
    end
  end

  describe "verdict words" do
    it "names verdicts in plain words" do
      expect(helper.verdict_words("as_is")).to eq("landed as posted")
      expect(helper.verdict_words("modified")).to eq("modified before commit")
      expect(helper.verdict_words("partial")).to eq("part of a posted patchset")
      expect(helper.verdict_words("from_discussion")).to eq("written from the discussion, no matching patch")
      expect(helper.verdict_words("undecided")).to eq("undecided")
      expect(helper.verdict_words("odd_one")).to eq("odd one")
    end

    it "names coverage in plain words" do
      expect(helper.coverage_words("final")).to eq("saw the final version")
      expect(helper.coverage_words("earlier")).to eq("saw an earlier version")
      expect(helper.coverage_words("none")).to eq("no review found")
      expect(helper.coverage_words(nil)).to eq("no review found")
    end
  end
end
