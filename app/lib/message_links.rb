module MessageLinks
  LINK_RE = %r{(?:postgr\.es/m/|postgresql\.org/message-id/(?:flat/)?)([^\s<>"'()\[\]]+)}i

  def self.message_ids(body)
    MessageBodyText.strip_quotes(body).scan(LINK_RE).map do |(raw)|
      raw = raw.sub(/#.*\z/, "")
      next if raw.match?(/%(?!\h\h)/)

      id = URI.decode_uri_component(raw)
      next unless id.valid_encoding?

      id.sub(%r{[.,;:/]+\z}, "").presence
    end.compact.uniq
  end

  HASH_RE = /\b[0-9a-f]{8,40}\b/

  def self.commit_tokens(body)
    MessageBodyText.strip_quotes(body).scan(HASH_RE).select { _1.match?(/[a-f]/) }.uniq
  end
end
