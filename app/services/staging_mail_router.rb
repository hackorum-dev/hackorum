# Mail interceptor for staging: real delivery only when every recipient is on
# the allowlist, everything else goes to the sink (mailpit) with recipients
# untouched so the original addressing stays visible there.
class StagingMailRouter
  HEADER = "X-Hackorum-Staging-Routed"

  attr_reader :allowlist, :sink_host, :sink_port

  def self.from_env(env = ENV)
    list = env.fetch("STAGING_MAIL_ALLOWLIST", "").split(",").map { |s| s.strip.downcase }.reject(&:empty?)
    new(
      allowlist: list,
      sink_host: env.fetch("STAGING_MAIL_SINK_HOST", "mailpit"),
      sink_port: env.fetch("STAGING_MAIL_SINK_PORT", "1025").to_i
    )
  end

  def initialize(allowlist:, sink_host:, sink_port:)
    @allowlist = allowlist.map(&:downcase)
    @sink_host = sink_host
    @sink_port = sink_port
  end

  def delivering_email(mail)
    recipients = Array(mail.to) + Array(mail.cc) + Array(mail.bcc)
    if recipients.any? && recipients.all? { |r| allowed?(r) }
      Rails.logger.info("[staging_mail] real delivery to #{recipients.join(', ')}")
      return
    end

    mail.delivery_method(:smtp, address: sink_host, port: sink_port,
                         enable_starttls_auto: false, authentication: nil,
                         user_name: nil, password: nil)
    mail[HEADER] = "sink"
    Rails.logger.info("[staging_mail] routed to sink, recipients: #{recipients.join(', ').presence || '(none)'}")
  end

  private

  def allowed?(address)
    addr = address.to_s.strip.downcase
    return false if addr.empty?
    domain = addr.split("@", 2).last
    allowlist.any? do |entry|
      entry.start_with?("@") ? entry == "@#{domain}" : entry == addr
    end
  end
end
