require "rails_helper"

RSpec.describe Lineage::DiffParser do
  UNIFIED = <<~DIFF
    From 1234567890123456789012345678901234567890 Mon Sep 17 00:00:00 2001
    From: Someone <s@example.com>
    Subject: [PATCH v3 2/5] Teach the planner a trick

    ---
     src/backend/optimizer/plan.c | 2 +-
    diff --git a/src/backend/optimizer/plan.c b/src/backend/optimizer/plan.c
    --- a/src/backend/optimizer/plan.c
    +++ b/src/backend/optimizer/plan.c
    @@ -1,3 +1,4 @@
     int a;
    -int b;
    +int   c;
    +--- not a header
     int d;
    diff --git a/src/test/regress/sql/old.sql b/src/test/regress/sql/old.sql
    --- a/src/test/regress/sql/old.sql
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -select 1;
  DIFF

  CONTEXT = <<~DIFF
    *** src/backend/x.c\t2004-01-01
    --- src/backend/x.c\t2004-01-02
    ***************
    *** 1,3 ****
      keep
    ! old line
    - gone
    --- 1,3 ----
      keep
    ! new line
    + added
  DIFF

  it "parses unified diffs with hunk counting" do
    r = described_class.parse(UNIFIED)
    plan = r.files.find { |f| f.path == "src/backend/optimizer/plan.c" }
    expect(plan.area).to eq(:code)
    expect(plan.removed).to eq(Set["int b;"])
    expect(plan.added).to eq(Set["int c;", "--- not a header"])
    gone = r.files.find { |f| f.path == "src/test/regress/sql/old.sql" }
    expect(gone.area).to eq(:test)
    expect(gone.removed).to eq(Set["select 1;"])
    expect(r.subjects).to eq([ "Teach the planner a trick" ])
  end

  it "parses context diffs" do
    r = described_class.parse(CONTEXT)
    expect(r.files.size).to eq(1)
    f = r.files.first
    expect(f.path).to eq("src/backend/x.c")
    expect(f.removed).to eq(Set["old line", "gone"])
    expect(f.added).to eq(Set["new line", "added"])
  end

  it "gives each file of a multi-file context diff its own entry" do
    text = <<~DIFF
      *** src/a.c\tD
      --- src/a.c\tD
      ***************
      *** 1,2 ****
        a
      ! old a
      --- 1,2 ----
        a
      ! new a
      *** src/b.c\tD
      --- src/b.c\tD
      ***************
      *** 1,2 ****
        b
      ! old b
      --- 1,2 ----
        b
      ! new b
    DIFF
    r = described_class.parse(text)
    expect(r.files.map(&:path)).to eq([ "src/a.c", "src/b.c" ])
    expect(r.files.map(&:added)).to eq([ Set["new a"], Set["new b"] ])
    expect(r.files.map(&:removed)).to eq([ Set["old a"], Set["old b"] ])
  end

  it "parses plain diff -u output without diff --git lines" do
    text = <<~DIFF
      --- src/a.c\tD
      +++ src/a.c\tD
      @@ -1,4 +1,3 @@
       a
      -b
       c
       d
      --- src/b.c\tD
      +++ src/b.c\tD
      @@ -1,3 +1,4 @@
       x
       y
      +w
       z
    DIFF
    r = described_class.parse(text)
    expect(r.files.map(&:path)).to eq([ "src/a.c", "src/b.c" ])
    expect(r.files[0].removed).to eq(Set["b"])
    expect(r.files[1].added).to eq(Set["w"])
  end

  it "does not let a deletion-only context hunk swallow the next file" do
    text = <<~DIFF
      *** src/a.c\tD
      --- src/a.c\tD
      ***************
      *** 1,4 ****
        a
      - b
        c
        d
      --- 1,3 ----
      *** src/b.c\tD
      --- src/b.c\tD
      ***************
      *** 1,3 ****
      --- 1,4 ----
        x
        y
      + w
        z
    DIFF
    r = described_class.parse(text)
    expect(r.files.map(&:path)).to eq([ "src/a.c", "src/b.c" ])
    expect(r.files[0].removed).to eq(Set["b"])
    expect(r.files[0].added).to be_empty
    expect(r.files[1].added).to eq(Set["w"])
    expect(r.files[1].removed).to be_empty
  end

  it "ends a context hunk when a file header shows up on the new side" do
    text = <<~DIFF
      *** src/a.c\tD
      --- src/a.c\tD
      ***************
      *** 1,4 ****
        a
      - b
      ! c
        d
      --- 1,4 ----
      *** src/b.c\tD
      --- src/b.c\tD
      ***************
      *** 1,3 ****
      --- 1,4 ----
        x
      + w
    DIFF
    r = described_class.parse(text)
    expect(r.files.map(&:path)).to eq([ "src/a.c", "src/b.c" ])
    expect(r.files[1].added).to eq(Set["w"])
  end

  it "uses the Index: path when the context header has a bare basename" do
    text = <<~DIFF
      Index: src/test/regress/sql/foo.sql
      ===================================================================
      *** foo.sql\t2004-01-01
      --- foo.sql\t2004-01-02
      ***************
      *** 1,2 ****
      --- 1,3 ----
        a
      + select 1;
      Index: src/backend/Makefile
      ===================================================================
      *** Makefile\t2004-01-01
      --- Makefile\t2004-01-02
      ***************
      *** 1,2 ****
      --- 1,3 ----
        a
      + CFLAGS=1
    DIFF
    r = described_class.parse(text)
    expect(r.files.map(&:path)).to eq([ "src/test/regress/sql/foo.sql", "src/backend/Makefile" ])
    expect(r.files[0].area).to eq(:test)
    expect(r.files[0].added).to eq(Set["select 1;"])
    expect(r.files[1].added).to eq(Set["CFLAGS=1"])
  end

  it "uses the Index: path when a unified header has a bare basename" do
    text = <<~DIFF
      Index: src/test/regress/sql/foo.sql
      ===================================================================
      RCS file: /cvsroot/pgsql/src/test/regress/sql/foo.sql,v
      retrieving revision 1.2
      diff -u -r1.2 foo.sql
      --- foo.sql\t1 Jan 2004 00:00:00 -0000\t1.2
      +++ foo.sql\t2 Jan 2004 00:00:00 -0000
      @@ -1,2 +1,3 @@
       a
      +select 1;
       b
      Index: src/backend/gone.c
      ===================================================================
      RCS file: /cvsroot/pgsql/src/backend/gone.c,v
      diff -u -r1.1 gone.c
      --- gone.c\t1 Jan 2004 00:00:00 -0000\t1.1
      +++ /dev/null\t1 Jan 1970 00:00:00 -0000
      @@ -1,1 +0,0 @@
      -int x;
    DIFF
    r = described_class.parse(text)
    expect(r.files.map(&:path)).to eq([ "src/test/regress/sql/foo.sql", "src/backend/gone.c" ])
    expect(r.files[0].area).to eq(:test)
    expect(r.files[0].added).to eq(Set["select 1;"])
    expect(r.files[1].removed).to eq(Set["int x;"])
  end

  it "parses non-utf8 bytes without breaking json" do
    text = "From #{'a' * 40} Mon Sep 17 00:00:00 2001\nSubject: [PATCH] caf\xE9 fix\n\n---\n" \
           "--- a/x.c\n+++ b/x.c\n@@ -1,1 +1,2 @@\n a\n+caf\xE9\n"
    r = described_class.parse(text.b)
    expect { JSON.generate(r.subjects) }.not_to raise_error
    expect { JSON.generate(r.files.first.added.to_a) }.not_to raise_error
    expect(r.files.first.added.size).to eq(1)
  end

  it "reassembles folded and encoded subjects" do
    text = <<~DIFF
      From #{'a' * 40} Mon Sep 17 00:00:00 2001
      From: Someone <s@example.com>
      Subject: [PATCH 1/2] A very long subject that
       was folded by format-patch
      Date: today

      --- a/x.c
      +++ b/x.c
      @@ -1,1 +1,2 @@
       a
      +b
      From #{'b' * 40} Mon Sep 17 00:00:00 2001
      Subject: =?UTF-8?q?=5BPATCH_2/2=5D_caf=C3=A9_done?=

    DIFF
    r = described_class.parse(text)
    expect(r.subjects).to eq([ "A very long subject that was folded by format-patch", "caf\u00e9 done" ])
  end

  it "splits header paths on any whitespace" do
    text = <<~DIFF
      --- src/x.c 2004-01-01 10:00:00 +0100
      +++ src/x.c 2004-01-02 10:00:00 +0100
      @@ -1,1 +1,2 @@
       a
      +b
    DIFF
    expect(described_class.parse(text).files.map(&:path)).to eq([ "src/x.c" ])
  end

  it "ignores Subject: lines outside a mbox header" do
    text = <<~DIFF
      Subject: not a patch subject
      --- a/x.c
      +++ b/x.c
      @@ -1,1 +1,2 @@
       a
      +b
    DIFF
    expect(described_class.parse(text).subjects).to eq([])
  end

  it "parses new-file and deleted-file context diffs" do
    text = <<~DIFF
      *** /dev/null\t1970
      --- src/new.c\t2004
      ***************
      *** 0 ****
      --- 1,2 ----
      + one
      + two
      *** src/old.c\t2004
      --- /dev/null\t1970
      ***************
      *** 1,2 ****
      - three
      - four
      --- 0 ----
    DIFF
    r = described_class.parse(text)
    expect(r.files.map(&:path)).to eq([ "src/new.c", "src/old.c" ])
    expect(r.files[0].added).to eq(Set["one", "two"])
    expect(r.files[1].removed).to eq(Set["three", "four"])
  end

  it "memoizes line sets per area" do
    r = described_class.parse(UNIFIED)
    added, removed = r.lines
    expect(added).to include("int c;")
    expect(removed).to include("select 1;")
    expect(r.lines).to equal(r.lines)
    expect(r.lines(:test)[1]).to eq(Set["select 1;"])
  end

  it "merges several files and keeps subject order" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "0001-a.patch")
      b = File.join(dir, "0002-b.patch")
      File.write(a, UNIFIED)
      File.write(b, UNIFIED.sub("2/5] Teach the planner a trick", "3/5] Second"))
      r = described_class.parse_files([ a, b ])
      expect(r.subjects).to eq([ "Teach the planner a trick", "Second" ])
      expect(r.files.map(&:path).uniq.size).to eq(2)
    end
  end

  it "classifies areas" do
    expect(described_class.area_for("src/test/regress/sql/x.sql")).to eq(:test)
    expect(described_class.area_for("contrib/foo/t/001_basic.pl")).to eq(:test)
    expect(described_class.area_for("doc/src/sgml/ref/x.sgml")).to eq(:docs)
    expect(described_class.area_for("configure")).to eq(:other)
    expect(described_class.area_for("src/backend/x.c")).to eq(:code)
  end
end
