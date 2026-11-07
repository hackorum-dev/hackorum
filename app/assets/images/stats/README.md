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
