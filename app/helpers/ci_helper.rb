module CiHelper
  CI_BADGES = {
    "success" => [ "b-success", "success" ],
    "tests_failed" => [ "b-testsfail", "tests failed" ],
    "tests_timeout" => [ "b-testsfail", "tests timeout" ],
    "build_failed" => [ "b-buildfail", "build failed" ],
    "build_timeout" => [ "b-buildfail", "build timeout" ],
    "running" => [ "b-running", "running" ],
    "queued" => [ "b-queued", "queued" ],
    "pushed_awaiting_ci" => [ "b-queued", "waiting for runner" ],
    "push_failed" => [ "b-infra", "push failed" ],
    "infra_error" => [ "b-infra", "infra error" ],
    "cancelled" => [ "b-queued", "cancelled" ],
    "ci_none" => [ "b-queued", "no CI" ]
  }.freeze

  CI_TIER_BADGES = {
    new_version: [ "b-newver", "new version" ],
    rebase: [ "b-rebase", "rebase" ],
    backfill: [ "b-backfill", "backfill" ]
  }.freeze

  CI_TIER_WORK = {
    new_version: "apply + push",
    rebase: "re-apply on master + push",
    backfill: "push"
  }.freeze

  # css + label. The health panel, the State badge and the state facet chip all
  # read their words off here, so the same bucket cannot be called two things.
  CI_BUCKET_BADGES = {
    "applies" => [ "b-success", "applies" ],
    "needs_rebase" => [ "b-rebase", "needs rebase" ],
    "awaiting_ci" => [ "b-queued", "awaiting CI" ],
    "wont_retry" => [ "b-infra", "won't retry" ],
    "never_applied" => [ "b-buildfail", "never applied" ]
  }.freeze

  CI_BASE_TIER_BADGES = {
    "recent" => "b-success",
    "stale" => "b-rebase",
    "ancient" => "b-buildfail",
    "unknown" => "b-queued"
  }.freeze

  # muted on purpose: recency is an ops signal, not a per-row verdict, so it
  # must not compete with the State badge beside it
  CI_CHECK_TIER_BADGES = {
    "current" => "b-queued",
    "behind" => "b-queued",
    "overdue" => "b-rebase",
    "never" => "b-queued"
  }.freeze

  # what lands in a bucket, in one line. Only the buckets whose panel has no
  # live breakdown of its own - awaiting_ci and wont_retry build theirs from
  # counts, so they are absent here on purpose.
  CI_BUCKET_BLURBS = {
    "applies" => "applied on master when last tried",
    "needs_rebase" => "the last apply on master failed, still retrying",
    "never_applied" => "extract, base detection or apply failed"
  }.freeze

  # what each /ci/branches facet row is called; facet names are prose, but every
  # facet *value* renders lowercase in this feature, chip and badge alike
  FACET_LABELS = {
    base: "base age",
    state: "state",
    check: "master check",
    pg: "pg major",
    result: "result"
  }.freeze

  # codepoints so grepping this file for the arrows finds the one definition
  # rather than two glyphs. U+25BE/U+25B4 are the small down/up triangles.
  SORT_ARROWS = { "desc" => 0x25BE.chr("UTF-8"), "asc" => 0x25B4.chr("UTF-8") }.freeze
  ARIA_SORT = { "desc" => "descending", "asc" => "ascending" }.freeze

  GITHUB_URL = "https://github.com".freeze
  SHORT_SHA_CHARS = 9
  DIGEST_LABEL_CHARS = 14

  def ci_status_label(status)
    ci_badge_for(status).last
  end

  # title carries the branch's ci_skip_reason for infra/push failures
  def ci_status_badge(status, title: nil)
    css, label = ci_badge_for(status)
    css = "#{css} ci-hover" if title.present?
    tag.span(label, class: "badge #{css}", title: title.presence)
  end

  def ci_tier_badge(kind)
    css, label = CI_TIER_BADGES.fetch(kind)
    tag.span(label, class: "badge #{css}")
  end

  def ci_tier_work(kind)
    CI_TIER_WORK[kind]
  end

  # /ci/branches health bucket label - same badge look as ci_tier_badge
  def ci_bucket_badge(bucket)
    css, label = ci_bucket_pair(bucket)
    tag.span(label, class: "badge #{css}")
  end

  # the badge's own words, for callers that want them without the badge
  def ci_bucket_label(bucket)
    ci_bucket_pair(bucket).last
  end

  def ci_bucket_blurb(bucket)
    CI_BUCKET_BLURBS[bucket.to_s]
  end

  # tier badge plus a compact behind figure; the exact numbers stay in the
  # title so a narrow column does not cost precision
  def ci_base_tier_badge(row, repo_state)
    tier = row.base_tier.to_s
    css = CI_BASE_TIER_BADGES.fetch(tier, "b-queued")
    label = [ tier, ci_behind_label(row.behind_days(repo_state)) ].compact.join(" ")
    tag.span(label, class: "badge #{css} ci-hover", title: ci_behind_title(row, repo_state))
  end

  # no figure beside the tier: the tiers already carry the only threshold that
  # matters, and the exact stamp is a hover away
  def ci_check_tier_badge(row)
    tier = row.check_tier.to_s
    css = CI_CHECK_TIER_BADGES.fetch(tier, "b-queued")
    tag.span(tier, class: "badge #{css} ci-hover", title: ci_check_title(row))
  end

  def ci_check_title(row)
    stamp = row.last_master_apply_at
    return "never tried on master" unless stamp
    "last tried on master #{time_ago_in_words(stamp)} ago"
  end

  def ci_behind_label(days)
    return nil unless days
    days = [ days, 0 ].max
    return "#{days}d" if days < 60
    return "#{(days / 30.0).round}mo" if days < 365
    "#{(days / 365.0).round}y"
  end

  def ci_behind_title(row, repo_state)
    parts = ci_behind_parts(row, repo_state)
    parts ? "#{parts} behind master" : "no base metadata"
  end

  def ci_work_reason(item, repo_state)
    case item.kind
    when :new_version then "patch posted #{time_ago_in_words(item.message.created_at)} ago"
    when :backfill then "applied, never pushed"
    when :rebase
      row = item.patch_branch
      # read on_master before the probe timestamp, same order bucket_sql uses.
      # A row off master already lost an apply to master; most of them predate
      # the probe columns, so keying on those would call a known conflict
      # unchecked.
      if row.master_apply_error.present?
        "master apply failing, retrying"
      elsif !row.on_master
        "not on master, retrying"
      elsif row.last_master_apply_at.nil?
        "master moved since it was built"
      else
        "last checked #{time_ago_in_words(row.last_master_apply_at)} ago"
      end
    end
  end

  # the "why" of an infra/push failure lives on the branch, not the run
  SKIP_REASON_STATUSES = %w[infra_error push_failed].freeze

  def ci_skip_reason_for(row)
    return nil unless SKIP_REASON_STATUSES.include?(row.ci_status)
    row.ci_skip_reason.presence
  end

  def ci_duration(seconds)
    return "-" if seconds.blank?
    "#{seconds / 60}m #{format('%02d', seconds % 60)}s"
  end

  def ci_percent(value, precision: 1)
    return ci_muted_dash if value.nil?
    number_to_percentage(value * 100, precision: precision)
  end

  def ci_stat_count(value)
    number_with_delimiter(value.to_i)
  end

  def ci_short_sha(sha)
    sha.to_s.first(SHORT_SHA_CHARS).presence
  end

  # t<topic>_<index>: the index is the patchset number the site already shows,
  # so read it back rather than recomputing it - same as Pusher#message_index.
  # nil rather than garbage if a branch name ever stops matching the format.
  def ci_patchset_index(row)
    row.branch_name.to_s[/_(\d+)\z/, 1]
  end

  # the five stages ApplyOne can fail at, in words. "error" is its catch-all
  # for an exception, which "failed at error" would not convey.
  FAILURE_STAGE_PHRASES = {
    "extract" => "patch extract failed",
    "base_detection" => "no usable base commit",
    "apply" => "apply failed",
    "error" => "apply crashed",
    # deliberately not "apply failed": it did not, it produced nothing. The
    # failure_reason on the row says which of the ways that happened.
    "empty" => "applied but changed nothing"
  }.freeze

  # the index icon: glyph names the stage the patch is at or died at, tone
  # carries the verdict. Two glyphs belong to the apply stage alone and no CI
  # outcome can wear them, so the glyph alone tells them apart even read in
  # grayscale.
  TopicIcon = Struct.new(:glyph, :tone, :label)

  # retired for a reason that is not a verdict on the patch. The commit icon
  # beside it already says the thread landed, and a merged thread's patchsets
  # belong to the thread it merged into - an icon here would be a second, worse
  # answer to a question already answered.
  CI_QUIET_REASONS = [ "committed", "merged thread" ].freeze

  # this is the hover-card headline, not the badge chip - CI_BADGES owns that
  # register. The two are independent on purpose, so a label matching or
  # echoing a CI_BADGES one (tests failed, infra error) is coincidence, not a
  # link to keep in sync.
  CI_RUN_ICONS = {
    "success" => [ "fa-circle-check", "green", "CI passed" ],
    "tests_failed" => [ "fa-flask", "amber", "tests failed" ],
    "tests_timeout" => [ "fa-flask", "amber", "tests timed out" ],
    "build_failed" => [ "fa-hammer", "red", "build failed" ],
    "build_timeout" => [ "fa-hammer", "red", "build timed out" ],
    "infra_error" => [ "fa-plug-circle-exclamation", "purple", "infrastructure error" ],
    "push_failed" => [ "fa-plug-circle-exclamation", "purple", "push failed" ],
    "cancelled" => [ "fa-plug-circle-exclamation", "muted", "run cancelled" ]
  }.freeze

  # an applying row with no mapped status has no result at all rather than one
  # in progress: bucket_sql routes every in-flight status to awaiting_ci first,
  # so nil is the only value that reaches here
  CI_NO_RESULT_ICON = [ "fa-hourglass-half", "muted", "applies, no CI result" ].freeze

  # the one-phrase "what became of this patchset", for a row with nothing to
  # expand. A row that reached CI says it in badges instead.
  def ci_patchset_outcome(row)
    return FAILURE_STAGE_PHRASES.fetch(row.failure_stage, "apply failed") if row.status == "failed"
    return "applied, never pushed" if row.pushed_at.nil?
    nil
  end

  def ci_github_branch_url(branch_name)
    "#{GITHUB_URL}/#{PatchCi::Config::GITHUB_REPO}/tree/#{branch_name}"
  end

  def ci_github_commit_url(sha)
    "#{GITHUB_URL}/#{PatchCi::Config::GITHUB_REPO}/commit/#{sha}"
  end

  def ci_github_compare_url(base_sha, head_sha)
    "#{GITHUB_URL}/#{PatchCi::Config::GITHUB_REPO}/compare/#{base_sha}...#{head_sha}"
  end

  # attempt 1 has no /attempts page worth linking - the run URL already lands
  # on it, and the suffix would just be noise on every first-try run
  def ci_github_run_url(run)
    url = "#{GITHUB_URL}/#{PatchCi::Config::GITHUB_REPO}/actions/runs/#{run.github_run_id}"
    run.run_attempt > 1 ? "#{url}/attempts/#{run.run_attempt}" : url
  end

  # the one "nothing to show here" mark, so a table cannot grow a second one
  def ci_muted_dash
    tag.span("-", class: "muted")
  end

  def ci_result_cell(row)
    return ci_muted_dash if row.ci_status.blank?
    ci_status_badge(row.ci_status, title: ci_skip_reason_for(row))
  end

  # an in-flight row has no durations yet, so the same cell carries how long
  # it has been out there. Nothing to count from without a push time, and a
  # finished run's durations would be a lie about the one in flight.
  def ci_timing_cell(row)
    if PatchCiRun::IN_FLIGHT_BRANCH_STATUSES.include?(row.ci_status)
      return ci_muted_dash if row.pushed_at.nil?
      tag.span("#{ci_elapsed_minutes(row.pushed_at)} elapsed", class: "muted")
    elsif (run = row.latest_run_summary)
      ci_duration_pair(run)
    else
      ci_muted_dash
    end
  end

  # a run still out there has no durations yet, so the same cell carries how
  # long it has been going - same trade as ci_timing_cell makes for a branch
  def ci_run_timing_cell(run)
    unless run.terminal?
      since = run.started_at || run.queued_at
      return since ? tag.span("#{ci_elapsed_minutes(since)} elapsed", class: "muted") : ci_muted_dash
    end
    ci_duration_pair(run)
  end

  def ci_image_cell(row)
    ci_image_command_cell(row.latest_run_summary, live: true)
  end

  # ghcr tag is :t<topic_id> - one tag for the whole topic, overwritten by
  # every run in it. Only the newest run that built one can still offer the
  # tag; the rest offer the digest they recorded, which nothing overwrites.
  def ci_image_command_cell(run, live:)
    ref = live ? (run&.image_ref).presence : ci_digest_ref(run)
    return ci_muted_dash if ref.blank?
    cmd = ci_docker_command(ref)
    tag.code(ci_docker_label(ref), class: "ci-copy", title: cmd,
             data: { controller: "clipboard", action: "click->clipboard#copy",
                     "clipboard-url-value": cmd })
  end

  def ci_tests_cell(row)
    ci_tests_figure(row.latest_run_summary)
  end

  # hover: false where the failure list is already on the page - the run table
  # folds it out, and the same 200 names twice in one row is not a hint
  def ci_tests_figure(run, hover: true)
    return ci_muted_dash if run.nil? || run.tests_total.blank?
    # a partial payload can report more failures than it reports tests
    passed = [ run.tests_total - run.failed_tests.size, 0 ].max
    text = "#{passed} / #{run.tests_total}"
    return tag.span(text) if !hover || run.failed_tests.empty?
    tag.span(text, class: "ci-hover", title: "Failed: #{run.failed_tests.join(', ')}")
  end

  def ci_docker_command(image_ref)
    "docker run --rm -p 5432:5432 #{image_ref}"
  end

  # rpartition, not split: a registry host may carry a port, and only the
  # trailing :tag is the tag
  def ci_digest_ref(run)
    return nil if run.nil? || run.image_ref.blank? || run.image_digest.blank?
    repo = run.image_ref.rpartition(":").first.presence || run.image_ref
    "#{repo}@#{run.image_digest}"
  end

  def ci_docker_label(image_ref)
    return "docker run ... :#{image_ref.split(':').last}" unless image_ref.include?("@")
    "docker run ... @#{image_ref.split('@').last.slice(0, DIGEST_LABEL_CHARS)}..."
  end

  def ci_elapsed_minutes(since)
    return "-" unless since
    "#{((Time.current - since) / 60).floor}m"
  end

  # a run is dated by the last thing that happened to it; an unclaimed push
  # has none of the three
  def ci_run_when(run)
    stamp = run.completed_at || run.started_at || run.queued_at
    return "-" unless stamp
    smart_time_display(stamp)
  end

  # the aliases are raw json text out of a hostile payload, so a nested object
  # would otherwise render as json on the page
  def ci_ccache_line(run)
    return nil unless run.ccache_hit.to_s.match?(/\A\d+\z/) && run.ccache_miss.to_s.match?(/\A\d+\z/)
    "ccache #{run.ccache_hit} hit / #{run.ccache_miss} miss"
  end

  def ci_facet_label(facet)
    FACET_LABELS.fetch(facet)
  end

  # one chip per facet value, toggling only its own value: the other facets and
  # the sort ride along in active_params, which never carries page.
  # Links inside the frame need no turbo data of their own - they target the
  # enclosing frame, and it carries the visit action.
  def ci_facet_chip(query, facet, value, count: nil)
    selected = query.selected(facet)
    active = selected.include?(value)
    values = active ? selected - [ value ] : selected + [ value ]
    text = ci_facet_value_label(facet, value)
    text = "#{text} (#{number_with_delimiter(count)})" if count
    link_to text,
            ci_branches_path(query.active_params.merge(facet => values.join(",")).compact_blank),
            class: ("is-active" if active), aria: { current: ("true" if active) }
  end

  def ci_facet_all_chip(query, facet)
    active = query.selected(facet).empty?
    link_to "all", ci_branches_path(query.active_params.except(facet)),
            class: ("is-active" if active), aria: { current: ("true" if active) }
  end

  # clicking the active column flips direction, any other column starts desc.
  # No query means the dashboard sections, which share the partial but have
  # nothing to sort - plain header there.
  def ci_sort_header(query, key, label, numeric: false)
    return tag.th(label, class: ("num" if numeric)) if query.nil?

    active = query.sort_key == key
    dir = active && query.sort_dir == "desc" ? "asc" : "desc"
    arrow = active ? " #{SORT_ARROWS.fetch(query.sort_dir)}" : ""
    classes = [ ("num" if numeric), "sortable", ("is-active" if active) ].compact.join(" ")
    tag.th(class: classes, aria: { sort: (ARIA_SORT.fetch(query.sort_dir) if active) }) do
      link_to "#{label}#{arrow}", ci_branches_path(query.active_params.merge(sort: key, dir: dir))
    end
  end

  # nil means render nothing at all - the one visibility rule, so the index
  # icon and the two thread blocks cannot disagree about which threads have
  # something to say about CI
  def ci_topic_icon(row)
    return nil if row.nil?

    case row.health_bucket
    when "wont_retry" then ci_retired_icon(row)
    when "never_applied" then ci_never_applied_icon(row)
    when "needs_rebase" then TopicIcon.new("fa-code-merge", "amber", "does not apply to master")
    when "awaiting_ci" then ci_pending_icon(row)
    when "applies" then ci_applied_icon(row)
    end
  end

  # the thread blocks stay quiet on exactly the rows the index icon does - one
  # rule, so a thread cannot be worth an icon but not a block, or the reverse
  def ci_thread_visible?(status)
    status&.present? && ci_topic_icon(status.row).present?
  end

  # "patchset v3 (message #12)" - the index off the branch name, the number off
  # the numbering the thread page already built. Falls back to the index alone
  # rather than inventing a number.
  def ci_patchset_label(row, message_numbers)
    index = ci_patchset_index(row) || "?"
    number = message_numbers[row.message_id]
    number ? "patchset v#{index} (message ##{number})" : "patchset v#{index}"
  end

  # the tag is per topic and every run overwrites it, so the image a reader is
  # about to pull is whichever patchset finished last. Name it, or they test a
  # patch nobody is discussing.
  def ci_image_mismatch_warning(status, message_numbers)
    built = status.image_branch
    current = ci_patchset_label(status.row, message_numbers)
    return "This image was not built from the current #{current}." if built.nil?

    "This image is from #{ci_patchset_label(built, message_numbers)} - " \
      "the current #{current} has not produced an image."
  end

  # the one "build / test" pair, so a table cannot grow a second one with a
  # different blank case. Public: the thread sidebar calls it straight from
  # the view, like every other formatter here.
  def ci_duration_pair(run)
    return ci_muted_dash if run.build_seconds.blank? && run.test_seconds.blank?
    tag.span("#{ci_duration(run.build_seconds)} / #{ci_duration(run.test_seconds)}")
  end

  private

  def ci_retired_icon(row)
    return nil if CI_QUIET_REASONS.include?(row.wont_retry_reason)
    return TopicIcon.new("fa-plug-circle-exclamation", "muted", "retired, base too old") if row.wont_retry_reason == "base too old"
    TopicIcon.new("fa-plug-circle-exclamation", "purple", "CI skipped: #{row.wont_retry_reason}")
  end

  # empty is the one failure stage that is not a broken patch: the apply worked
  # and produced nothing, which usually means it is already upstream
  def ci_never_applied_icon(row)
    return TopicIcon.new("fa-file-circle-xmark", "muted", "applied but changed nothing") if row.failure_stage == "empty"
    TopicIcon.new("fa-file-circle-xmark", "red", FAILURE_STAGE_PHRASES.fetch(row.failure_stage, "apply failed"))
  end

  def ci_pending_icon(row)
    return TopicIcon.new("fa-hourglass-half", "blue", "CI running") if row.ci_status == "running"
    label = row.pushed_at.nil? ? "waiting to be pushed" : "waiting for CI"
    TopicIcon.new("fa-hourglass-half", "muted", label)
  end

  def ci_applied_icon(row)
    TopicIcon.new(*CI_RUN_ICONS.fetch(row.ci_status, CI_NO_RESULT_ICON))
  end

  # a chip reading "ci none" over a badge reading "no CI" is the same row
  # disagreeing with itself, so both facets whose values the table also renders
  # as badges take the label off the badge map. NO_RESULT is a sentinel with no
  # badge of its own.
  def ci_facet_value_label(facet, value)
    case facet
    when :result
      value == PatchCi::BranchQuery::NO_RESULT ? "no result" : ci_status_label(value)
    when :state then ci_bucket_label(value)
    else value.to_s.tr("_", " ")
    end
  end

  # the fallback keeps an unmapped bucket readable rather than blank
  def ci_bucket_pair(bucket)
    CI_BUCKET_BADGES.fetch(bucket.to_s, [ "b-queued", bucket.to_s.tr("_", " ") ])
  end

  # css + label pair; views take one or the other through the two wrappers
  def ci_badge_for(status)
    CI_BADGES.fetch(status.to_s, [ "b-queued", status.to_s.humanize.downcase ])
  end

  # nil when we know neither figure. clamped: a repo state fetched while a
  # push was in flight can trail the base, and "-2 days behind" is noise
  def ci_behind_parts(row, repo_state)
    days = row.behind_days(repo_state)
    commits = row.behind_commits(repo_state)
    [ days && "#{[ days, 0 ].max} days", commits && "#{[ commits, 0 ].max} commits" ]
      .compact.join(" / ").presence
  end
end
