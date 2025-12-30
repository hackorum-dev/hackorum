# frozen_string_literal: true

module MessageIdNormalizer
  def self.normalize(ref)
    return '' if ref.nil?

    ref_str = ref.to_s

    if ref_str.include?('<')
      matches = ref_str.scan(/<([^>]+)>/)
      ref_str = matches.last&.first || ref_str
    end

    # Allow RFC 5322 msg-id atext plus dot and @, strip anything else.
    ref_str.gsub(/[^A-Za-z0-9.!#$%&'*+\/=?^_`{|}~@-]/, '')
  end
end
