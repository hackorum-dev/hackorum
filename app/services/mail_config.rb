module MailConfig
  def self.dir = ENV["DMS_CONFIG_DIR"].presence
  def self.available? = dir.present?
  def self.domain = ENV["MAIL_DOMAIN"]
  def self.host = ENV["MAIL_HOST"]
  def self.webmail_host = ENV["WEBMAIL_HOST"]
end
