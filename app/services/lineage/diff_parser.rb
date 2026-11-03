module Lineage
  # Patch text -> per-file added/removed line sets. Unified and context diffs,
  # single patches or format-patch mboxes. Hunk line counts decide what is
  # content, so a removed "-- foo" never reads as a header.
  class DiffParser
    AREAS = %i[code test docs other].freeze
    AREA_RULES = [
      [ :test, %r{(\A|/)(src/test/|regress/|t/[^/]+\.pl\z|expected/|sql/)} ],
      [ :docs, %r{(\A|/)doc/|\.sgml\z} ],
      [ :other, %r{\Aconfigure(\.ac|\.in)?\z|\.m4\z|\.po\z|\Asrc/tools/pgindent/typedefs\.list\z} ]
    ].freeze

    FileDiff = Struct.new(:path, :area, :added, :removed, keyword_init: true)
    Result = Struct.new(:files, :subjects, keyword_init: true) do
      def changed_lines = files.sum { |f| f.added.size + f.removed.size }

      def lines(area = nil)
        @lines ||= {}
        @lines[area] ||= begin
          sel = area ? files.select { |f| f.area == area } : files
          [ sel.map(&:added).reduce(Set.new, :|), sel.map(&:removed).reduce(Set.new, :|) ]
        end
      end
    end

    HUNK_RE = /\A@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/
    CTX_OLD_RE = /\A\*\*\* \d+(?:,\d+)? \*\*\*\*/
    CTX_NEW_RE = /\A--- \d+(?:,\d+)? ----/
    MBOX_FROM_RE = /\AFrom [0-9a-f]{40} /
    CTX_HUNK_END_RE = /\A(\*\*\* |--- |\*{15}|diff |Index: )/
    SUBJECT_RE = /\ASubject: (.*)/

    def self.area_for(path)
      AREA_RULES.each { |area, re| return area if path.match?(re) }
      :code
    end

    def self.parse(text) = new.parse(text)

    def self.parse_files(paths)
      results = paths.map { |p| new.parse(File.binread(p)) }
      Result.new(files: results.flat_map(&:files), subjects: results.flat_map(&:subjects))
    end

    def parse(text)
      @files = []
      @subjects = []
      @current = nil
      @pending_path = nil
      @index_path = nil
      @in_header = false
      @subject_open = false
      @subject_raw = nil
      @old_left = @new_left = 0
      @ctx_side = nil

      text.dup.force_encoding(Encoding::UTF_8).each_line do |raw|
        line = raw.chomp.scrub
        in_hunk = @old_left.positive? || @new_left.positive?
        if in_hunk
          consume_content(line)
        else
          consume_marker(line)
        end
      end
      Result.new(files: @files, subjects: @subjects)
    end

    private

    def consume_marker(line)
      if @subject_open
        if line.start_with?(" ", "\t")
          @subject_raw = "#{@subject_raw} #{line.strip}"
          @subjects[-1] = decode_subject(@subject_raw)
          return
        end
        @subject_open = false
        @in_header = false
      end

      if line.match?(MBOX_FROM_RE)
        @in_header = true
      elsif @in_header && (m = line.match(SUBJECT_RE))
        @subject_raw = m[1].strip
        @subjects << decode_subject(@subject_raw)
        @subject_open = true
      elsif line.start_with?("diff --git ")
        @pending_path = nil
        @index_path = nil
        @current = nil
      elsif line.start_with?("Index: ")
        @index_path = PatchPathExtractor.normalize(line[7..].strip)
        @pending_path = @index_path
      elsif (m = line.match(CTX_OLD_RE))
        start_hunk_context(m)
      elsif line.match?(CTX_NEW_RE)
        start_context_new_side(line)
      elsif line.start_with?("*** ")
        @current = nil
        header_path(line)
      elsif line.start_with?("--- ")
        header_path(line)
      elsif line.start_with?("+++ ")
        header_path(line)
        open_file(@pending_path)
      elsif (m = line.match(HUNK_RE))
        open_file(@pending_path) unless @current
        @old_left = (m[1] || 1).to_i
        @new_left = (m[2] || 1).to_i
        @ctx_side = nil
      end
    end

    def decode_subject(raw)
      Mail::Encodings.value_decode(raw).to_s.scrub.strip.sub(/\A\[PATCH[^\]]*\]\s*/, "")
    rescue StandardError
      raw.sub(/\A\[PATCH[^\]]*\]\s*/, "")
    end

    def header_path(line)
      p = PatchPathExtractor.normalize(line[4..][/\S+/].to_s)
      p = @index_path if @index_path && (p.nil? || !p.include?("/"))
      @pending_path = p if p
    end

    def start_context_new_side(line)
      @ctx_side = :new
      # GNU diff omits the new side when the old side had only "- " lines
      @new_left = @saw_minus && !@saw_bang ? 0 : range_count(line)
    end

    def start_hunk_context(m)
      open_file(@pending_path) unless @current
      @ctx_side = :old
      @saw_bang = @saw_minus = false
      @old_left = range_count(m[0])
      @new_left = 0
    end

    def range_count(header)
      nums = header.scan(/\d+/).map(&:to_i)
      return 0 if nums == [ 0 ]
      nums.size >= 2 ? nums[1] - nums[0] + 1 : 1
    end

    def consume_content(line)
      if @ctx_side
        consume_context(line)
      else
        consume_unified(line)
      end
    end

    def consume_unified(line)
      case line[0]
      when "+" then add(line[1..]); @new_left -= 1
      when "-" then remove(line[1..]); @old_left -= 1
      when "\\" then nil
      else @old_left -= 1; @new_left -= 1
      end
    end

    def consume_context(line)
      if @ctx_side == :old && line.match?(CTX_NEW_RE)
        @old_left = 0
        start_context_new_side(line)
        return
      end
      tag = line[0, 2]
      if @ctx_side == :old
        @saw_bang = true if tag == "! "
        @saw_minus = true if tag == "- "
        remove(line[2..]) if [ "! ", "- " ].include?(tag)
        @old_left -= 1
      else
        # a file header here means the hunk ended early
        if line.match?(CTX_HUNK_END_RE) && !line.match?(CTX_NEW_RE)
          @old_left = @new_left = 0
          @ctx_side = nil
          return consume_marker(line)
        end
        add(line[2..]) if [ "! ", "+ " ].include?(tag)
        @new_left -= 1
      end
    end

    def open_file(path)
      @index_path = nil
      return @current = nil if path.nil?
      @current = FileDiff.new(path: path, area: self.class.area_for(path), added: Set.new, removed: Set.new)
      @files << @current
      @pending_path = nil
    end

    def add(content)
      n = normalize(content)
      @current&.added&.add(n) if n
    end

    def remove(content)
      n = normalize(content)
      @current&.removed&.add(n) if n
    end

    def normalize(content)
      s = content.to_s.strip.squeeze(" \t")
      s.empty? ? nil : s
    end
  end
end
