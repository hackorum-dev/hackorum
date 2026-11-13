module LineageHelper
  MSG_TOKEN = /\[msg:(\d+)\]/
  COMMIT_TOKEN = /\[commit:([0-9a-f]{40})\]/
  VERDICT_WORDS = {
    "as_is" => "landed as posted",
    "modified" => "modified before commit",
    "partial" => "part of a posted patchset",
    "from_discussion" => "written from the discussion, no matching patch",
    "undecided" => "undecided"
  }.freeze
  COVERAGE_WORDS = { "final" => "saw the final version", "earlier" => "saw an earlier version" }.freeze
  STEP_WORDS = {
    "new_series" => "new series",
    "minor_revision" => "small revision",
    "major_rework" => "reworked version",
    "fix_on_top" => "fix on top",
    "rebase" => "rebase",
    "remainder" => "rest",
    "resend" => "resend"
  }.freeze
  STEP_JOINERS = { "remainder" => "after a partial commit" }.freeze
  CHANGE_LEVEL_TITLE = "light = formatting, naming, comments, tests; moderate = local logic; significant = approach changed".freeze

  def verdict_words(verdict)
    VERDICT_WORDS.fetch(verdict.to_s) { verdict.to_s.tr("_", " ") }
  end

  def coverage_words(coverage)
    COVERAGE_WORDS.fetch(coverage.to_s, "no review found")
  end

  def lineage_step_words(step_kind, parent_ordinal)
    words = STEP_WORDS.fetch(step_kind.to_s) { step_kind.to_s.tr("_", " ") }
    return [ words, nil, nil ] unless parent_ordinal

    [ words, parent_ordinal, STEP_JOINERS[step_kind.to_s] ]
  end

  def llm_percent(confidence)
    "#{(confidence.to_f * 100).round}%"
  end

  def llm_confidence_label(confidence)
    "LLM analysis, #{llm_percent(confidence)} sure"
  end

  def lineage_text(text, ordinals)
    return "" if text.blank?

    html = ERB::Util.html_escape(text)
    html = html.gsub(MSG_TOKEN) do
      id = Regexp.last_match(1).to_i
      link_to("##{ordinals[id] || id}", "#message-#{id}")
    end
    html = html.gsub(COMMIT_TOKEN) do
      sha = Regexp.last_match(1)
      link_to(sha[0, 10], commit_web_url(sha), target: "_blank", rel: "noopener")
    end
    html.html_safe
  end

  def lineage_plain(text, ordinals)
    return "" if text.blank?

    text.gsub(MSG_TOKEN) { "##{ordinals[Regexp.last_match(1).to_i] || Regexp.last_match(1)}" }
        .gsub(COMMIT_TOKEN) { Regexp.last_match(1)[0, 10] }
  end

  def lineage_ordinals(topic)
    topic.messages.order(:created_at).pluck(:id).each_with_index.to_h { |id, i| [ id, i + 1 ] }
  end

  def story_chapters(lines, chapters)
    current = 0
    grouped = lines.map do |line|
      ref = line[MSG_TOKEN, 1]
      index = ref && chapters.index_of(ref.to_i)
      current = index if index
      [ current, line ]
    end
    grouped.group_by(&:first).sort_by(&:first).map { |index, pairs| [ index, pairs.map(&:last) ] }
  end

  def story_dot_class(line, revert_shas)
    sha = line[COMMIT_TOKEN, 1]
    return "is-talk" unless sha

    revert_shas.any? { |s| s.start_with?(sha) } ? "is-revert" : "is-commit"
  end
end
