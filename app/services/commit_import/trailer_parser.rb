module CommitImport
  class TrailerParser
    Person = Struct.new(:role, :name, :email, keyword_init: true)
    Result = Struct.new(:people, :message_ids, :cherry_picked_from, keyword_init: true)

    ROLES = {
      "reviewed-by" => "reviewer",
      "author" => "author",
      "reported-by" => "reported_by",
      "co-authored-by" => "co_author",
      "tested-by" => "tested_by"
    }.freeze

    MSGID_RE = %r{
      (?:postgr\.es|postgre\.es|(?:www\.)?postgresql\.org)
      /(?:m|message-id)/
      ([^\s>"\]]+)
    }ix

    # /message-id/attachment/<n>/<file> is a patch download, not a message.
    ATTACHMENT_PREFIX = "attachment/".freeze

    CHERRY_PICK_RE = /cherry picked from commit\s+([0-9a-f]{8,40})\b/i
    TRAILER_RE = /\A([A-Za-z][A-Za-z-]*):[ \t]*(.*)\z/

    # Anything after the email is a note ("(in absentia)", "(earlier
    # version)"). A name with an unclosed paren means the email sits inside
    # a note about someone else, so it is not this person's.
    ANGLE_EMAIL_RE = /\A([^<>]*?)\s*<+([^<>\s]+@[^<>\s]+)(?:>+.*)?\z/
    PAREN_EMAIL_RE = /\A([^()<>]*?)\s*\(\s*<?([^\s()<>]+@[^\s()<>]+?)>?\s*\)\z/
    NOTE_RE = /\A\s*\([^()]*\)\s*|\s*\([^()]*\)\s*\z/
    COMMA_SEP = /\G,/
    AND_SEP = /\G\s+and\s+/i

    def initialize(subject:, body:)
      @subject = subject.to_s
      @body = body.to_s
    end

    def parse
      Result.new(people: people, message_ids: message_ids, cherry_picked_from: cherry_picked_from)
    end

    def people
      trailers.flat_map do |key, value|
        role = ROLES[key]
        next [] unless role

        split_entries(value).map { |entry| person_for(role, entry) }
      end
    end

    def message_ids
      text.scan(MSGID_RE).flatten
          .map { |id| strip_url_noise(id) }
          .reject { |id| id.empty? || id.start_with?(ATTACHMENT_PREFIX) }
          .uniq
    end

    def cherry_picked_from
      text[CHERRY_PICK_RE, 1]
    end

    private

    def text
      "#{@subject}\n#{@body}"
    end

    # An indented line continues the trailer directly above it. Anything else
    # (blank line, prose) breaks the chain, so indented prose never gets
    # appended to a trailer further up the message.
    def trailers
      found = []
      continuing = false

      @body.each_line do |raw|
        line = raw.rstrip

        if line.empty?
          continuing = false
          next
        end

        if continuing && line.match?(/\A[ \t]/)
          found.last[1] = "#{found.last[1]} #{line.strip}".squeeze(" ")
          next
        end

        m = line.match(TRAILER_RE)
        if m
          found << [ m[1].downcase, m[2].strip ]
          continuing = true
        else
          continuing = false
        end
      end

      found
    end

    def split_entries(value)
      parts = merge_incomplete_parts(split_people(value, COMMA_SEP))
      parts.flat_map { |part| split_people(part, AND_SEP) }.map(&:strip).reject(&:empty?)
    end

    def split_people(value, sep)
      split_top_level(value, sep, nesting: true) || split_top_level(value, sep, nesting: false)
    end

    # Never splits inside <...>. With nesting, not inside (...) or "..."
    # either, as notes and quoted "Last, First" names hold separators too.
    # Returns nil when a paren or quote is left open, so the caller can
    # retry without nesting.
    def split_top_level(value, sep, nesting:)
      parts = []
      buffer = +""
      angle = 0
      paren = 0
      quoted = false
      i = 0

      while i < value.length
        if angle.zero? && paren.zero? && !quoted && (m = value.match(sep, i))
          parts << buffer
          buffer = +""
          i = m.end(0)
          next
        end

        char = value[i]
        case char
        when "<" then angle += 1
        when ">" then angle -= 1 if angle.positive?
        when "(" then paren += 1 if nesting
        when ")" then paren -= 1 if paren.positive?
        when '"' then quoted = !quoted if nesting
        end
        buffer << char
        i += 1
      end

      return nil if paren.positive? || quoted

      parts << buffer
      parts
    end

    # A comma only separates people when both sides end up with their own
    # "<email>". Plain "Last, First <email>" for one person has no bracket
    # on the first half, so glue it back onto the next part instead -- but
    # only when that first half is a single bare surname, not a full name
    # or an email of its own. Otherwise we'd fabricate a composite name out
    # of two separate people (e.g. "Robert Haas, Tom Lane").
    def merge_incomplete_parts(parts)
      merged = []
      i = 0

      while i < parts.size
        part = parts[i]
        nxt = parts[i + 1]

        if merge_forward?(part, nxt)
          merged << "#{part},#{nxt}"
          i += 2
        else
          merged << part
          i += 1
        end
      end

      merged
    end

    # Known limitation: only a SINGLE-token bare fragment counts as a
    # possible surname half, so "van Rossum, Guido <g@x>" splits into two
    # people ("van Rossum" bare, "Guido" with the email) instead of one.
    # Accepted on purpose -- the alternative (also merging a multi-word
    # fragment) would instead wrongly merge genuine multi-person lists like
    # "Alice Smith, Tels <tels@x>", and multi-person lists plus single-token
    # names (e.g. Tels) are far more common in PostgreSQL history than a
    # multi-word surname in "Last, First" form. When it does happen, the
    # cost is one extra bare-name credit that will not resolve to a person;
    # the emailed half still resolves fine.
    def merge_forward?(part, next_part)
      return false unless next_part

      stripped = part.strip
      return false if part.match?(/<[^>]+>/)
      return false unless stripped.match?(/\A\S+\z/)
      return false if stripped.include?("@")

      next_part.match?(/<[^>]+>/)
    end

    def person_for(role, entry)
      entry = entry.delete('"').strip
      m = entry.match(ANGLE_EMAIL_RE)
      m = nil if m && m[1].count("(") != m[1].count(")")
      m ||= entry.match(PAREN_EMAIL_RE)
      return Person.new(role: role, name: m[1].strip.presence, email: m[2].strip.downcase) if m

      name = entry.gsub(NOTE_RE, "").presence || entry
      return Person.new(role: role, name: nil, email: name.downcase) if bare_email?(name)

      Person.new(role: role, name: name, email: nil)
    end

    def bare_email?(entry)
      entry.include?("@") && !entry.include?(" ")
    end

    # Everything the archive puts around an id but that is not part of it: a
    # flat/raw view prefix, a "#<id>" anchor the archive appends to its own
    # links, a doubled or trailing slash, and sentence punctuation from the
    # surrounding prose.
    def strip_url_noise(id)
      id.sub(%r{\A(?:flat|raw)/}i, "")
        .split("#").first.to_s
        .sub(/[).,;]+\z/, "")
        .gsub(%r{\A/+|/+\z}, "")
    end
  end
end
