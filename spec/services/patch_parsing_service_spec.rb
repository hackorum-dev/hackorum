require 'rails_helper'

RSpec.describe PatchParsingService, type: :service do
  let(:attachment) { create(:attachment, :text_file) }
  let(:service) { PatchParsingService.new(attachment) }

  describe "#parse!" do
    context "with a unified diff patch" do
      let(:patch_content) do
        <<~PATCH
          diff --git a/src/backend/optimizer/path/allpaths.c b/src/backend/optimizer/path/allpaths.c
          index 1234567..abcdefg 100644
          --- a/src/backend/optimizer/path/allpaths.c
          +++ b/src/backend/optimizer/path/allpaths.c
          @@ -123,6 +123,10 @@ some_function()
           {
               existing_code();
          +    /* New optimization */
          +    if (enable_new_feature)
          +        new_optimization();
          +
               more_existing_code();
           }

          diff --git a/contrib/pg_stat_statements/pg_stat_statements.c b/contrib/pg_stat_statements/pg_stat_statements.c
          index 2345678..bcdefgh 100644
          --- a/contrib/pg_stat_statements/pg_stat_statements.c
          +++ b/contrib/pg_stat_statements/pg_stat_statements.c
          @@ -456,7 +456,7 @@ another_function()
           {
          -    old_implementation();
          +    new_implementation();
           }
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "creates patch file records for each modified file" do
        expect { service.parse! }.to change(PatchFile, :count).by(2)

        patch_files = attachment.patch_files.order(:filename)

        expect(patch_files.first.filename).to eq("contrib/pg_stat_statements/pg_stat_statements.c")
        expect(patch_files.first.status).to eq("modified")

        expect(patch_files.second.filename).to eq("src/backend/optimizer/path/allpaths.c")
        expect(patch_files.second.status).to eq("modified")
      end

      it "counts line changes correctly" do
        service.parse!

        backend_file = attachment.patch_files.find_by(filename: "src/backend/optimizer/path/allpaths.c")
        contrib_file = attachment.patch_files.find_by(filename: "contrib/pg_stat_statements/pg_stat_statements.c")

        expect(backend_file.line_changes).to eq(4) # 4 added lines (3 code + 1 blank)
        expect(contrib_file.line_changes).to eq(2) # 1 removed, 1 added
      end
    end

    context "with file additions and deletions" do
      let(:patch_content) do
        <<~PATCH
          diff --git a/src/backend/new_feature.c b/src/backend/new_feature.c
          new file mode 100644
          index 0000000..1234567
          --- /dev/null
          +++ b/src/backend/new_feature.c
          @@ -0,0 +1,10 @@
          +/* New feature implementation */
          +#include "postgres.h"
          +
          +void new_feature(void)
          +{
          +    /* Implementation */
          +}

          diff --git a/src/backend/old_feature.c b/src/backend/old_feature.c
          deleted file mode 100644
          index abcdefg..0000000
          --- a/src/backend/old_feature.c
          +++ /dev/null
          @@ -1,5 +0,0 @@
          -/* Old feature - being removed */
          -void old_feature(void)
          -{
          -    /* Old implementation */
          -}
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "correctly identifies added and deleted files" do
        service.parse!

        patch_files = attachment.patch_files.order(:filename)

        new_file = patch_files.find_by(filename: "src/backend/new_feature.c")
        old_file = patch_files.find_by(filename: "src/backend/old_feature.c")

        expect(new_file.status).to eq("added")
        expect(old_file.status).to eq("deleted")
      end
    end

    context "with a context diff patch" do
      let(:patch_content) do
        <<~PATCH
          *** a/src/backend/access/gist/gistproc.c
          --- b/src/backend/access/gist/gistproc.c
          ***************
          *** 26,31 **** static bool gist_box_leaf_consistent(BOX *key, BOX *query,
          --- 26,35 ----
            static double size_box(Datum dbox);
            static bool rtree_internal_consistent(BOX *key, BOX *query,
                              StrategyNumber strategy);
          + static BOX *empty_box(void);
          +#{' '}
          + /* Minimal possible ratio of split */
          + #define LIMIT_RATIO 0.3


          ***************
          *** 49,78 **** rt_box_union(PG_FUNCTION_ARGS)
          --- 53,58 ----
            	PG_RETURN_BOX_P(n);
            }
          #{'  '}
          - static Datum
          - rt_box_inter(PG_FUNCTION_ARGS)
          - {
          - 	BOX		   *a = PG_GETARG_BOX_P(0);
          - 	BOX		   *b = PG_GETARG_BOX_P(1);
          - 	BOX		   *n;
          -#{' '}
          - 	n = (BOX *) palloc(sizeof(BOX));
          -#{' '}
          - 	n->high.x = Min(a->high.x, b->high.x);
          - 	n->high.y = Min(a->high.y, b->high.y);
          - 	n->low.x = Max(a->low.x, b->low.x);
          - 	n->low.y = Max(a->low.y, b->low.y);
          -#{' '}
          - 	if (n->high.x < n->low.x || n->high.y < n->low.y)
          - 	{
          - 		pfree(n);
          - 		/* Indicate "no intersection" by returning NULL pointer */
          - 		n = NULL;
          - 	}
          -#{' '}
          - 	PG_RETURN_BOX_P(n);
          - }
          -#{' '}
            /*
             * The GiST Consistent method for boxes
             *
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "creates patch file record for context diff format" do
        expect { service.parse! }.to change(PatchFile, :count).by(1)

        patch_file = attachment.patch_files.first
        expect(patch_file.filename).to eq("src/backend/access/gist/gistproc.c")
        expect(patch_file.status).to eq("modified")
      end

      it "counts line changes correctly in context diff" do
        service.parse!

        patch_file = attachment.patch_files.first
        expect(patch_file.line_changes).to eq(28) # 4 added + 24 removed
      end
    end

    context "with multi-file context diff patch" do
      let(:patch_content) do
        <<~PATCH
          *** a/src/backend/access/gist/gistproc.c
          --- b/src/backend/access/gist/gistproc.c
          ***************
          *** 26,31 ****
          --- 26,35 ----
            static double size_box(Datum dbox);
          + static BOX *empty_box(void);
          + #define LIMIT_RATIO 0.3

          *** a/contrib/cube/cube.c
          --- b/contrib/cube/cube.c
          ***************
          *** 45,50 ****
          --- 45,55 ----
            #include "postgres.h"
          + #include "utils/array.h"
          +#{' '}
          + /* New cube function */
          + static void cube_init(void);
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "creates patch file records for multiple files" do
        expect { service.parse! }.to change(PatchFile, :count).by(2)

        patch_files = attachment.patch_files.order(:filename)

        expect(patch_files.first.filename).to eq("contrib/cube/cube.c")
        expect(patch_files.first.status).to eq("modified")

        expect(patch_files.second.filename).to eq("src/backend/access/gist/gistproc.c")
        expect(patch_files.second.status).to eq("modified")
      end
    end

    context "with context diff file rename" do
      let(:patch_content) do
        <<~PATCH
          *** a/src/backend/old_name.c
          --- b/src/backend/new_name.c
          ***************
          *** 1,5 ****
          --- 1,10 ----
            #include "postgres.h"
          +#{' '}
          + /* Renamed file with changes */
          + static void new_function(void);
          + static int new_variable = 0;
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "correctly identifies renamed files" do
        service.parse!

        patch_file = attachment.patch_files.first
        expect(patch_file.filename).to eq("src/backend/new_name.c")
        expect(patch_file.old_filename).to eq("src/backend/old_name.c")
        expect(patch_file.status).to eq("renamed")
      end
    end

    context "with CVS-style context diff patch" do
      let(:patch_content) do
        <<~PATCH
          Index: src/include/tsearch/ts_public.h
          ===================================================================
          RCS file: /home/postgres/devel/pgsql-cvs/pgsql/src/include/tsearch/ts_public.h,v
          retrieving revision 1.10
          diff -c -r1.10 ts_public.h
          *** src/include/tsearch/ts_public.h	18 Jun 2008 18:42:54 -0000	1.10
          --- src/include/tsearch/ts_public.h	2 Aug 2008 02:40:27 -0000
          ***************
          *** 52,59 ****
          --- 52,61 ----
            	int4		curwords;
            	char	   *startsel;
            	char	   *stopsel;
          + 	char	   *fragdelim;
            	int2		startsellen;
            	int2		stopsellen;
          + 	int2		fragdelimlen;
            } HeadlineParsedText;

          Index: src/backend/tsearch/wparser_def.c
          ===================================================================
          RCS file: /home/postgres/devel/pgsql-cvs/pgsql/src/backend/tsearch/wparser_def.c,v
          retrieving revision 1.15
          diff -c -r1.15 wparser_def.c
          *** src/backend/tsearch/wparser_def.c	17 Jun 2008 16:09:06 -0000	1.15
          --- src/backend/tsearch/wparser_def.c	2 Aug 2008 15:25:46 -0000
          ***************
          *** 1684,1701 ****
          --- 1684,1695 ----
            	return false;
            }

          - Datum
          - prsd_headline(PG_FUNCTION_ARGS)
          - {
          - 	HeadlineParsedText *prs;
          - 	return result;
          - }
          + static void mark_fragment(void)
          + {
          + 	/* New implementation */
          + }
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "creates patch file records for CVS format" do
        expect { service.parse! }.to change(PatchFile, :count).by(2)

        patch_files = attachment.patch_files.order(:filename)

        expect(patch_files.first.filename).to eq("src/backend/tsearch/wparser_def.c")
        expect(patch_files.first.status).to eq("modified")

        expect(patch_files.second.filename).to eq("src/include/tsearch/ts_public.h")
        expect(patch_files.second.status).to eq("modified")
      end

      it "extracts filenames correctly from CVS timestamps" do
        service.parse!

        filenames = attachment.patch_files.pluck(:filename).sort
        expect(filenames).to eq([
          "src/backend/tsearch/wparser_def.c",
          "src/include/tsearch/ts_public.h"
        ])
      end

      it "counts line changes correctly in CVS format" do
        service.parse!

        header_file = attachment.patch_files.find_by(filename: "src/include/tsearch/ts_public.h")
        backend_file = attachment.patch_files.find_by(filename: "src/backend/tsearch/wparser_def.c")

        expect(header_file.line_changes).to eq(2) # 2 added lines
        expect(backend_file.line_changes).to eq(10) # 6 removed + 4 added
      end
    end

    context "with traditional unified diff patch" do
      let(:patch_content) do
        <<~PATCH
          diff -ruN pgstattuple.orig/Makefile pgstattuple/Makefile
          --- pgstattuple.orig/Makefile	2006-02-27 21:54:40.000000000 +0900
          +++ pgstattuple/Makefile	2006-08-14 09:28:58.000000000 +0900
          @@ -6,7 +6,7 @@
           #
           #-------------------------------------------------------------------------
          #{' '}
          -SRCS		= pgstattuple.c
          +SRCS		= pgstattuple.c pgstatindex.c
          #{' '}
           MODULE_big	= pgstattuple
           OBJS		= $(SRCS:.c=.o)
          diff -ruN pgstattuple.orig/pgstatindex.c pgstattuple/pgstatindex.c
          --- pgstattuple.orig/pgstatindex.c	1970-01-01 09:00:00.000000000 +0900
          +++ pgstattuple/pgstatindex.c	2006-08-14 11:24:23.000000000 +0900
          @@ -0,0 +1,5 @@
          +/*
          + * pgstatindex - new file
          + */
          +#include "postgres.h"
          +void pgstatindex_main(void);
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "creates patch file records for traditional unified diff" do
        expect { service.parse! }.to change(PatchFile, :count).by(2)

        patch_files = attachment.patch_files.order(:filename)

        expect(patch_files.first.filename).to eq("Makefile")
        expect(patch_files.first.status).to eq("modified")

        expect(patch_files.second.filename).to eq("pgstatindex.c")
        expect(patch_files.second.status).to eq("modified")
      end

      it "extracts clean filenames from version paths" do
        service.parse!

        filenames = attachment.patch_files.pluck(:filename).sort
        expect(filenames).to eq([ "Makefile", "pgstatindex.c" ])
      end

      it "counts line changes correctly" do
        service.parse!

        makefile = attachment.patch_files.find_by(filename: "Makefile")
        new_file = attachment.patch_files.find_by(filename: "pgstatindex.c")

        expect(makefile.line_changes).to eq(2) # 1 removed + 1 added
        expect(new_file.line_changes).to eq(5) # 5 added lines
      end
    end

    context "with unified diff without diff command line" do
      let(:patch_content) do
        <<~PATCH
          --- Makefile.port.old	2011-09-15 10:27:20.000000000 +0200
          +++ Makefile.port	2011-09-19 10:12:32.247300770 +0200
          @@ -60,11 +60,11 @@
           PGICOSTR = $(subst /,\\/,IDI_ICON ICON \"$(top_builddir)/src/port/$(PGAPPICON).ico\")
           endif
          #{' '}
          -win32ver.rc: $(top_srcdir)/src/port/win32ver.rc
          -	sed -e 's;FILEDESC;$(PGFILEDESC);' $< >$@
          -
          -win32ver.o: win32ver.rc
          -	$(WINDRES) -i $< -o $@
          +#win32ver.rc: $(top_srcdir)/src/port/win32ver.rc
          +#	sed -e 's;FILEDESC;$(PGFILEDESC);' $< >$@
          +#
          +#win32ver.o: win32ver.rc
          +#	$(WINDRES) -i $< -o $@
          #{' '}
           # Rule for building a shared library
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "creates patch file record from --- +++ headers only" do
        expect { service.parse! }.to change(PatchFile, :count).by(1)

        patch_file = attachment.patch_files.first
        expect(patch_file.filename).to eq("Makefile.port")
        expect(patch_file.status).to eq("modified")
      end

      it "treats filename differences as modifications not renames" do
        service.parse!

        patch_file = attachment.patch_files.first
        expect(patch_file.filename).to eq("Makefile.port")
        expect(patch_file.old_filename).to be_nil # Traditional diff differences aren't renames
        expect(patch_file.status).to eq("modified")
      end

      it "counts line changes correctly" do
        service.parse!

        patch_file = attachment.patch_files.first
        expect(patch_file.line_changes).to eq(10) # 5 removed + 5 added
      end
    end

    context "with CVS traditional diff patch" do
      let(:patch_content) do
        <<~PATCH
          Index: postmaster.c
          ===================================================================
          RCS file: /projects/cvsroot/pgsql/src/backend/postmaster/postmaster.c,v
          retrieving revision 1.551.2.1
          diff -r1.551.2.1 postmaster.c
          1917c1917,1925
          < 		load_hba();
          ---
          >         if (access(HbaFileName, R_OK) == 0)
          >         {
          >             load_hba();
          >         }
          >         else
          >         {
          >             ereport(WARNING,
          >                 (errmsg("HBA file %s is unreadable, not reloading", HbaFileName)));
          >         }
          Index: src/backend/utils/init/globals.c
          ===================================================================
          RCS file: /projects/cvsroot/pgsql/src/backend/utils/init/globals.c,v
          retrieving revision 1.89.2.1
          diff -r1.89.2.1 globals.c
          45a46,47
          > char	   *HbaFileName = NULL;
          > char	   *IdentFileName = NULL;
          52d53
          < char	   *HbaFileName = NULL;
        PATCH
      end

      before do
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "creates patch file records for CVS traditional format" do
        expect { service.parse! }.to change(PatchFile, :count).by(2)

        patch_files = attachment.patch_files.order(:filename)

        expect(patch_files.first.filename).to eq("postmaster.c")
        expect(patch_files.first.status).to eq("modified")

        expect(patch_files.second.filename).to eq("src/backend/utils/init/globals.c")
        expect(patch_files.second.status).to eq("modified")
      end

      it "counts line changes correctly in CVS traditional format" do
        service.parse!

        postmaster_file = attachment.patch_files.find_by(filename: "postmaster.c")
        globals_file = attachment.patch_files.find_by(filename: "src/backend/utils/init/globals.c")

        expect(postmaster_file.line_changes).to eq(10) # 1 removed + 9 added
        expect(globals_file.line_changes).to eq(3) # 2 added + 1 removed
      end

      it "extracts filenames from Index lines" do
        service.parse!

        filenames = attachment.patch_files.pluck(:filename).sort
        expect(filenames).to eq([ "postmaster.c", "src/backend/utils/init/globals.c" ])
      end
    end

    context "with ed diff format patch" do
      let(:patch_content) do
        <<~PATCH
          88a89,93
          >                 struct#{' '}
          > 		{
          > 	    		int sqlcode_varno;
          > 			int sqlerrm_varno;
          > 		}						fict_vars;
          104a110
          > %type <fict_vars> fict_vars_sect
          251c257
          < pl_block		: decl_sect K_BEGIN lno proc_sect exception_sect K_END
          ---
          > pl_block		: decl_sect fict_vars_sect K_BEGIN lno proc_sect exception_sect K_END
          259c265
          < 						new->lineno		= $3;
          ---
          > 						new->lineno		= $4;
          263,264c269,272
          < 						new->body		= $4;
          < 						new->exceptions	= $5;
          ---
          > 						new->body		= $5;
          > 						new->exceptions	= $6;
          >                                                 new->sqlcode_varno = $2.sqlcode_varno;
          > 						new->sqlerrm_varno = $2.sqlerrm_varno;
          271a280,291
          > fict_vars_sect            :
          > 					{
          >                                                 plpgsql_ns_setlocal(false);
          > 						PLpgSQL_variable	*var;
          >                                                 var = plpgsql_build_variable(strdup("sqlcode"), 0,
          > 									     plpgsql_build_datatype(TEXTOID, -1), true);#{'  '}
          > 						$$.sqlcode_varno = var->dno;
          >                                                 var = plpgsql_build_variable(strdup("sqlerrm"), 0,
          > 									     plpgsql_build_datatype(TEXTOID, -1), true);#{'  '}
          > 					        $$.sqlerrm_varno = var->dno;
          > 						plpgsql_add_initdatums(NULL);
          > 					}
          693a714
          >
        PATCH
      end

      before do
        attachment.file_name = "gram.y.diff"
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "creates patch file record for ed diff format" do
        expect { service.parse! }.to change(PatchFile, :count).by(1)

        patch_file = attachment.patch_files.first
        expect(patch_file.filename).to eq("gram.y")
        expect(patch_file.status).to eq("modified")
      end

      it "counts line changes correctly in ed diff format" do
        service.parse!

        patch_file = attachment.patch_files.first
        expect(patch_file.line_changes).to eq(29) # Count of added and removed lines
      end

      it "infers filename from attachment name" do
        service.parse!

        patch_file = attachment.patch_files.first
        expect(patch_file.filename).to eq("gram.y")
        expect(patch_file.old_filename).to be_nil
      end
    end

    context "with unified diff containing *** in content" do
      let(:patch_content) do
        <<~PATCH
          diff --git a/html/layout/js/sorttable.js b/html/layout/js/sorttable.js
          new file mode 100644
          index 0000000..25bccb2
          --- /dev/null
          +++ b/html/layout/js/sorttable.js
          @@ -0,0 +1,10 @@
          +/*
          +  SortTable
          +  version 2
          +  7th April 2007
          +  Stuart Langridge, http://www.kryogenix.org/code/browser/sorttable/
          +#{'  '}
          +  ****************************************************************** */
          +function sortTable() {
          +    // Implementation here
          +}

          diff --git a/template/header.tt2 b/template/header.tt2
          index abc1234..def5678 100644
          --- a/template/header.tt2
          +++ b/template/header.tt2
          @@ -10,6 +10,7 @@
           <head>
               <title>Test</title>
          +    <script src="sorttable.js"></script>
           </head>
           <body>
        PATCH
      end

      before do
        attachment.file_name = "add_sorttable.diff"
        allow(attachment).to receive(:decoded_body).and_return(patch_content)
      end

      it "correctly identifies as unified diff despite *** in content" do
        expect { service.parse! }.to change(PatchFile, :count).by(2)

        patch_files = attachment.patch_files.order(:filename)
        expect(patch_files.first.filename).to eq("html/layout/js/sorttable.js")
        expect(patch_files.first.status).to eq("added")
        expect(patch_files.second.filename).to eq("template/header.tt2")
        expect(patch_files.second.status).to eq("modified")
      end

      it "does not confuse *** in content with context diff headers" do
        service.parse!

        # Should create files, proving it was parsed as unified diff not context diff
        expect(attachment.patch_files.count).to eq(2)

        js_file = attachment.patch_files.find_by(filename: "html/layout/js/sorttable.js")
        expect(js_file.line_changes).to eq(10) # 10 added lines
      end
    end

    context "with non-patch attachment" do
      before do
        allow(attachment).to receive(:patch?).and_return(false)
      end

      it "does not create any patch file records" do
        expect { service.parse! }.not_to change(PatchFile, :count)
      end
    end

    context "when patch files already exist" do
      before do
        create(:patch_file, attachment: attachment, filename: "src/backend/test.c")
        allow(attachment).to receive(:decoded_body).and_return("diff --git a/src/backend/test.c")
      end

      it "does not duplicate existing records" do
        expect { service.parse! }.not_to change(PatchFile, :count)
      end
    end
  end

  describe "#extract_contrib_modules" do
    before do
      create(:patch_file, :contrib_file, attachment: attachment, filename: "contrib/pg_stat_statements/pg_stat_statements.c")
      create(:patch_file, :contrib_file, attachment: attachment, filename: "contrib/hstore/hstore_op.c")
      create(:patch_file, :backend_file, attachment: attachment)
    end

    it "returns unique contrib module names" do
      modules = service.extract_contrib_modules
      expect(modules).to match_array([ "pg_stat_statements", "hstore" ])
    end
  end

  describe "#extract_backend_areas" do
    before do
      create(:patch_file, attachment: attachment, filename: "src/backend/optimizer/path/allpaths.c")
      create(:patch_file, attachment: attachment, filename: "src/backend/executor/execMain.c")
      create(:patch_file, attachment: attachment, filename: "src/backend/optimizer/plan/planner.c")
    end

    it "returns unique backend area paths" do
      areas = service.extract_backend_areas
      expect(areas).to match_array([ "optimizer/path", "executor", "optimizer/plan" ])
    end
  end
end
