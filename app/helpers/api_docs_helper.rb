# frozen_string_literal: true

module ApiDocsHelper
  TOKEN_LABELS = { required: "required", optional: "optional", none: "not used" }.freeze

  # raw HTML in the text is escaped, not passed through
  def api_markdown(text)
    return if text.blank?

    @api_markdown ||= Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(escape_html: true, safe_links_only: true, link_attributes: { rel: "noopener" }),
      autolink: true, fenced_code_blocks: true, tables: true, no_intra_emphasis: true, strikethrough: true
    )
    @api_markdown.render(text).html_safe
  end

  def api_inline_markdown(text)
    html = api_markdown(text).to_s.strip
    inner = html.delete_prefix("<p>").delete_suffix("</p>")
    html.start_with?("<p>") && html.end_with?("</p>") && inner.exclude?("<p>") ? inner.html_safe : html.html_safe
  end

  def api_type(parts)
    safe_join(parts.map { |part| part.is_a?(Api::Reference::Link) ? link_to(part.name, "##{part.anchor}") : part })
  end

  def api_notes(node)
    lines = []
    if node.enum.present?
      lines << tag.div(safe_join([ "Values: ", safe_join(node.enum.map { |value| tag.code(value) }, ", ") ]), class: "api-note")
    end
    if node.notes.any?
      lines << tag.div(safe_join(node.notes.map { |label, value| value.nil? ? label : safe_join([ "#{label}: ", tag.code(value) ]) }, ", "),
                       class: "api-note")
    end
    safe_join(lines)
  end

  def api_status_class(status)
    "api-status-#{status.match?(/\A[1-5]/) ? status[0] : 'x'}"
  end
end
