module Lineage
  module References
    MESSAGE_FILE = %r{\bmessages/(\d+)\.txt\b}
    MESSAGE_ORDINAL = /\bmessages?\s*#(\d+)\b/i
    MESSAGE_ID = /\bmessage\s+(\d+)\b/i
    SHA = %r{(?<![\w:=/])\h{40}(?!\w)}

    def self.normalize(text, topic:, shas:, message_ids: nil)
      return text if text.blank?

      ids = message_ids || topic.chronological_message_ids
      known = ids.to_set
      ordinal = ->(n) { n.positive? && ids[n - 1] ? "[msg:#{ids[n - 1]}]" : nil }
      text.gsub(MESSAGE_FILE) { ordinal.call($1.to_i) || $& }
          .gsub(MESSAGE_ORDINAL) { ordinal.call($1.to_i) || $& }
          .gsub(MESSAGE_ID) { known.include?($1.to_i) ? "[msg:#{$1.to_i}]" : $& }
          .gsub(SHA) { shas.include?($&.downcase) ? "[commit:#{$&.downcase}]" : $& }
    end
  end
end
