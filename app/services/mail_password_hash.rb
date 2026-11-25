require "securerandom"

module MailPasswordHash
  PREFIX = "{SHA512-CRYPT}".freeze
  SALT_CHARS = [ *"a".."z", *"A".."Z", *"0".."9", ".", "/" ].freeze

  def self.create(plain)
    salt = Array.new(16) { SALT_CHARS[SecureRandom.random_number(SALT_CHARS.size)] }.join
    PREFIX + plain.to_s.crypt("$6$#{salt}")
  end

  def self.matches?(hash, plain)
    return false unless hash.to_s.start_with?(PREFIX)
    crypt = hash.delete_prefix(PREFIX)
    salt = crypt[/\A\$6\$[^$]+\$/]
    return false unless salt
    ActiveSupport::SecurityUtils.secure_compare(plain.to_s.crypt(salt), crypt)
  end
end
