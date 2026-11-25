module MailConfig
  def self.dir = ENV["DMS_CONFIG_DIR"].presence
  def self.available? = dir.present?
  def self.domain = ENV["MAIL_DOMAIN"]
  def self.host = ENV["MAIL_HOST"]
  def self.webmail_host = ENV["WEBMAIL_HOST"]

  # accounts the mailserver gets from its own config, not from mailboxes
  SYSTEM_ACCOUNTS = %w[receiver app].freeze

  # The mailserver looks accounts and quotas up with an unanchored grep ("." is a wildcard)
  # and takes the first line that matches, so a name can hit the line of a longer one.
  def self.tail_match?(pattern, name)
    name.match?(/#{Regexp.escape(pattern).gsub('\\.', '.')}\z/)
  end

  def self.mixed_up?(one, other)
    one != other && (tail_match?(one, other) || tail_match?(other, one))
  end
end
