# Stats index illustrations

Generated 2026-11-07 with the Codex CLI (codex-cli 0.164.0, `codex exec`,
image_generation feature enabled). All three came out of one run with the
prompt below, from a scratch directory:

    codex exec -s workspace-write --skip-git-repo-check -o last.txt "<prompt>"

Codex made them with its built-in `image_gen` tool (one call per file,
1774x887 originals under ~/.codex/generated_images). The first prompt
without the leading "use image_gen" sentence made Codex draw plain geometry
with a script instead, so keep that sentence when regenerating.

year.png and cycle.png were redone with the second prompt below because the
first versions had wide, flat content (4:1 and 5.6:1) that sat as a thin
strip in the card next to the full-height release.png.

## Post-processing rule

Every raw image goes through the same two steps so a regeneration is
reproducible (pure-Python PNG code, no PIL needed):

1. Crop to a 2:1 frame centred on the content bounding box (alpha > 8)
   with a 5 percent margin on the limiting axis, then resample to 1200x600
   with bilinear filtering on premultiplied alpha, alpha preserved.
2. Snap every opaque pixel to the nearest of #4f46e5, #a5b4fc and the
   accent #6366f1 (--color-primary-500); alpha stays as is.

## First prompt (all three; release.png comes from this run)

Use your built-in image generation tool (image_gen) for this, do not draw
with a script. Generate three illustrations for a statistics index page and
save them in this directory as release.png, year.png and cycle.png. Shared
style for all three: flat vector illustration, mostly indigo (#4f46e5) and
light indigo (#a5b4fc) with at most one accent tone, soft shapes, no text,
no gradients, no outlines, fully transparent background (PNG with alpha),
2:1 landscape, 1200x600 pixels. The subjects: release.png shows a version
tag or label being stamped out of a horizontal stream of small commit dots.
year.png shows a calendar strip of twelve tall columns with a few dots
scattered over them. cycle.png shows one long horizontal line (master) with
a second line forking off it and continuing in parallel. Keep each
composition centred with generous empty margins. Copy the generated files
into this directory under those names and report the three paths when done.

## Second prompt (year.png and cycle.png)

Use your built-in image generation tool (image_gen) for this, do not draw
with a script. Generate two illustrations for a statistics index page and
save them in this directory as year.png and cycle.png. Style: flat vector
illustration, mostly indigo (#4f46e5) and light indigo (#a5b4fc) with at
most one accent tone, soft shapes, no text, no gradients, no outlines,
fully transparent background (PNG with alpha), 2:1 landscape. Important
composition rule for both: the drawing itself must be about 2:1 in
proportion and fill the frame, about 90 percent of the height and 85
percent of the width, with only a thin empty margin; do not leave large
empty areas above and below. The subjects: year.png shows a calendar strip
of twelve tall narrow columns (rounded pills) standing side by side, each
column nearly as tall as the frame, with a few dots scattered over them.
cycle.png shows a git history: one long horizontal line (master) with
commit nodes running near the bottom of the frame, and a second line that
forks off it with a tall rising curve and continues in parallel near the
top of the frame, also with nodes, so the two lines together span most of
the height. Copy the generated files into this directory under those
names, unmodified, and report the two paths when done.

## release.png

A rubber stamp coming down on one dot of a horizontal stream of commit
dots, with an arrow to the version tag it produces.

## year.png

Twelve tall rounded columns in alternating indigo tones, nearly the full
height of the frame, with a few dots scattered over them.

## cycle.png

A dark master line with commit nodes along the bottom and a lighter line
rising steeply off it to run parallel along the top.

## Trend cards

Generated 2026-11-08 (codex-cli 0.164.0, same method, run with stdin from
/dev/null or codex waits for input). One run, one prompt, then the
post-processing rule above. Originals were 1774x887.

Prompt:

Use your built-in image generation tool (image_gen) for this, do not draw
with a script. Generate three illustrations for a statistics index page and
save them in this directory as release-trend.png, year-trend.png and
cycle-trend.png. Style: flat vector illustration, mostly indigo (#4f46e5)
and light indigo (#a5b4fc) with at most one accent tone, soft shapes, no
text, no gradients, no outlines, fully transparent background (PNG with
alpha), 2:1 landscape. The drawing must be about 2:1 and fill the frame,
about 90 percent of the height and 85 percent of the width. The subjects:
release-trend.png shows a row of version tags of rising height connected by
a line, like a chart made of labels. year-trend.png shows a row of small
calendar pages with a rising line drawn across their tops. cycle-trend.png
shows several parallel branch lines forking off one master line one after
another, each fork a little higher than the last. Copy the generated files
into this directory under those names, unmodified, and report the paths
when done.

release-trend.png: five tags in alternating indigo tones, rising in height,
strung on a rising line.

year-trend.png: five calendar pages of growing size with a rising line of
dots above them.

cycle-trend.png: a master line along the bottom with four branches forking
up one after another, each ending in a lighter bar, each higher than the last.

## Mailing list cards

Generated 2026-11-14 (codex-cli 0.167.0, same method, stdin from
/dev/null). One run, one prompt. Originals were 1774x887.

These came back with loose specks of noise around the shapes, so before the
post-processing rule above they get one extra step: keep only connected
regions of alpha > 128 larger than 0.2 percent of the image, grow that mask
by 3 pixels to keep the anti-aliased edges, and clear alpha everywhere
else.

Prompt:

Use your built-in image generation tool (image_gen) for this, do not draw
with a script. Generate three illustrations for a statistics index page and
save them in this directory as lists.png, newcomers.png and regulars.png.
Style: flat vector illustration, mostly indigo (#4f46e5) and light indigo
(#a5b4fc) with at most one accent tone, soft shapes, no text, no gradients,
no outlines, fully transparent background (PNG with alpha), 2:1 landscape.
The drawing must be about 2:1 and fill the frame, about 90 percent of the
height and 85 percent of the width. The subjects: lists.png shows a stack
of envelopes or message cards flowing into a row of stacked bars of varying
height, like mail traffic turning into a chart. newcomers.png shows a small
group of person silhouettes (simple round head and rounded body) standing
in a row, with one new figure stepping in from the side, slightly lighter,
approaching the group. regulars.png shows a podium-like ranking: a row of
rounded columns of different heights, each topped with a simple round
person head, with the tallest ones in the middle. Copy the generated files
into this directory under those names, unmodified, and report the paths
when done.

lists.png: three envelopes, an arrow, four stacked bars of rising height.

newcomers.png: four dark figures in a row and a lighter one walking in from
the right.

regulars.png: seven figures on columns, tallest in the middle, alternating
indigo tones.
