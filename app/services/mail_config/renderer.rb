module MailConfig
  class Renderer
    class MissingFragment < StandardError; end

    LOCK_KEY = "mail_config_render"
    ACCOUNT_LINE = /\A[^\s#|][^|]*\|/

    FILES = {
      "postfix-accounts.cf" => 0o640,
      "postfix-virtual.cf" => 0o644,
      "dovecot-quotas.cf" => 0o644,
      "sender-login.map" => 0o644
    }.freeze

    def self.call(dir: MailConfig.dir, domain: MailConfig.domain)
      return :skipped if dir.blank?
      raise ArgumentError, "MAIL_DOMAIN is not set" if domain.blank?
      new(dir, domain).call
    end

    def initialize(dir, domain)
      @dir = dir
      @domain = domain
    end

    def call
      AdvisoryLock.with_lock(LOCK_KEY, wait: true) do
        contents = build
        FILES.keys.select { |name| write(name, contents[name]) }
      end
    end

    private

    def build
      accounts = fragment("postfix-accounts.system.cf")
      virtual = fragment("postfix-virtual.system.cf")
      system_accounts = accounts.lines.map(&:chomp).grep(ACCOUNT_LINE).map { |l| l.split("|", 2).first.strip }
      raise MissingFragment, "postfix-accounts.system.cf has no accounts" if system_accounts.empty?

      taken = system_keys(accounts, virtual)
      mailboxes = enabled_mailboxes.reject { |m| collision?(taken, login(m)) }
      {
        "postfix-accounts.cf" => join(accounts, mailboxes.map { |m| "#{addr(login(m))}|#{m.password_hash}" }),
        "postfix-virtual.cf" => join(virtual, aliases(mailboxes, taken).sort.map { |a, l| "#{addr(a)} #{addr(l)}" }),
        "dovecot-quotas.cf" => join("", mailboxes.map { |m| "#{addr(login(m))}:#{m.quota_mb}M" }),
        "sender-login.map" => join(
          system_accounts.map { |a| "#{a} #{a}\n" }.join,
          mailboxes.flat_map { |m| sender_lines(m, taken) }
        )
      }
    end

    def enabled_mailboxes
      scope = Mailbox.enabled.joins(:user).where(users: { deleted_at: nil })
      scope = scope.where(users: { admin: true }) if Hackorum.staging?
      scope.includes(:addresses).filter_map { |m| m if login(m) }.sort_by { |m| login(m) }
    end

    def login(mailbox)
      mailbox.addresses.find(&:login?)&.local_part
    end

    def mailbox_aliases(mailbox, taken)
      mailbox.addresses.reject(&:login?).map(&:local_part).sort.reject { |a| collision?(taken, a) }
    end

    def aliases(mailboxes, taken)
      mailboxes.flat_map { |m| mailbox_aliases(m, taken).map { |a| [ a, login(m) ] } }
    end

    def sender_lines(mailbox, taken)
      login = login(mailbox)
      ([ login ] + mailbox_aliases(mailbox, taken)).map { |a| "#{addr(a)} #{addr(login)}" }
    end

    def system_keys(accounts, virtual)
      keys = accounts.lines.map(&:chomp).grep(ACCOUNT_LINE).map { |l| l.split("|", 2).first.strip }
      keys += virtual.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }.map { |l| l.split(/\s+/, 2).first }
      keys.map(&:downcase).to_set
    end

    def collision?(taken, local)
      return false unless taken.include?(addr(local).downcase)
      @logged ||= Set.new
      Rails.logger.error("mail config: #{addr(local)} collides with a system entry, skipped") if @logged.add?(local)
      true
    end

    def addr(local) = "#{local}@#{@domain}"

    def join(fragment, lines)
      fragment = "#{fragment}\n" if fragment.present? && !fragment.end_with?("\n")
      fragment + lines.map { |l| l.end_with?("\n") ? l : "#{l}\n" }.join
    end

    def fragment(name)
      path = File.join(@dir, name)
      raise MissingFragment, "#{name} is missing" unless File.file?(path)
      File.read(path)
    end

    def write(name, content)
      path = File.join(@dir, name)
      return false if File.file?(path) && File.read(path) == content

      tmp = File.join(@dir, ".#{name}.#{Process.pid}.tmp")
      FileUtils.rm_f(tmp)
      begin
        mode = FILES.fetch(name)
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) do |f|
          f.write(content)
          f.chmod(mode)
          f.fsync
        end
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp)
      end
      true
    end
  end
end
