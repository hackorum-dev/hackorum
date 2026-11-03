module LineageHelper
  MSG_TOKEN = /\[msg:(\d+)\]/
  COMMIT_TOKEN = /\[commit:([0-9a-f]{40})\]/

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
end
