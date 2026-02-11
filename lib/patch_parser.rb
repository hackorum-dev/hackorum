class PatchParser
  def initialize(patch_content, filename: nil, &file_handler)
    @patch_content = patch_content
    @filename = filename
    @file_handler = file_handler
  end

  def parse!
    return unless @patch_content.present?

    if @patch_content.match(/^\*\*\* /)
      parse_context_diff(@patch_content)
    elsif @patch_content.include?("Index:") && @patch_content.match(/^[<>]/)
      parse_cvs_traditional_diff(@patch_content)
    elsif @patch_content.match(/^\d+[acd]\d+/) && @patch_content.match(/^[<>]/)
      parse_ed_diff(@patch_content)
    else
      parse_unified_diff(@patch_content)
    end
  end

  private

  def parse_context_diff(content)
    current_file = nil
    lines = content.split("\n")

    i = 0
    while i < lines.length
      line = lines[i]

      # Look for file header pairs: "*** filename" followed by "--- filename"
      # File headers don't contain **** or ---- (those are hunk headers)
      # Handle both Git format (*** a/file) and CVS format (*** file timestamp)
      if line.match(/^\*\*\* ([^*\n]+)$/) && i + 1 < lines.length
        source_capture = $1
        next_line = lines[i + 1]

        # CVS format can have dashes in timestamps, so be more lenient
        if next_line.match(/^--- (.+)$/) && !next_line.include?("----")
          # This is a file header pair - validate it doesn't contain hunk markers
          handle_file(current_file) if current_file

          source_filename = source_capture.strip  # From the *** line
          target_filename = $1.strip  # From the --- line (current match)

          # Extract filename from Git format (a/file, b/file) or CVS format (file timestamp)
          source_filename = extract_filename_from_header(source_filename)
          target_filename = extract_filename_from_header(target_filename)

          current_file = {
            filename: target_filename,
            status: "modified",
            added_lines: 0,
            removed_lines: 0
          }

          # Check if this is a rename
          if source_filename != target_filename
            current_file[:old_filename] = source_filename
            current_file[:status] = "renamed"
          end

          i += 1 # Skip the next line since we processed it
        end
      elsif line.match(/^! /)
        # Changed line in context diff
        current_file[:added_lines] += 1 if current_file
        current_file[:removed_lines] += 1 if current_file
      elsif line.match(/^\+ /)
        # Added line in context diff
        current_file[:added_lines] += 1 if current_file
      elsif line.match(/^\- /)
        # Removed line in context diff
        current_file[:removed_lines] += 1 if current_file
      end

      i += 1
    end

    # Save the last file
    handle_file(current_file) if current_file
  end

  def parse_cvs_traditional_diff(content)
    current_file = nil
    lines = content.split("\n")

    i = 0
    while i < lines.length
      line = lines[i]

      # Look for CVS Index lines
      if line.match(/^Index: (.+)$/)
        handle_file(current_file) if current_file

        filename = $1.strip
        current_file = {
          filename: filename,
          status: "modified",
          added_lines: 0,
          removed_lines: 0
        }

      elsif line.match(/^[<>]/)
        # CVS traditional context format uses < for removed, > for added
        if line.start_with?("<")
          current_file[:removed_lines] += 1 if current_file
        elsif line.start_with?(">")
          current_file[:added_lines] += 1 if current_file
        end
      elsif line.match(/^\d+[acd]\d+/)
        # Line range indicators like "88a89,93" or "251c257" - these indicate changes but don't count as lines themselves
        # a = add, c = change, d = delete
      end

      i += 1
    end

    # Save the last file
    handle_file(current_file) if current_file
  end

  def parse_ed_diff(content)
    # Parse traditional ed/diff format that starts with line range indicators
    # like "88a89,93" and uses < for removed lines, > for added lines
    # Since there's no file header, we need to infer the filename from the attachment

    filename = @filename
    # Remove .diff extension if present
    filename = filename.sub(/\.diff$/, "") if filename&.end_with?(".diff")

    current_file = {
      filename: filename,
      status: "modified",
      added_lines: 0,
      removed_lines: 0
    }

    lines = content.split("\n")

    lines.each do |line|
      if line.match(/^</)
        # Removed line
        current_file[:removed_lines] += 1
      elsif line.match(/^>/)
        # Added line
        current_file[:added_lines] += 1
      elsif line.match(/^\d+[acd]\d+/)
        # Line range indicators - these indicate changes but don't count as lines themselves
        # a = add, c = change, d = delete
      elsif line == "---"
        # Separator line between removed and added content in change sections
      end
    end

    handle_file(current_file)
  end

  def parse_unified_diff(content)
    current_file = nil
    lines = content.split("\n")

    i = 0
    while i < lines.length
      line = lines[i]

      case line
      when /^diff --git a\/(.+) b\/(.+)$/
        # Git unified diff: Start of new file diff
        handle_file(current_file) if current_file
        current_file = {
          filename: $2, # Use the 'b/' version as canonical
          old_filename: ($1 != $2) ? $1 : nil,
          status: "modified",
          added_lines: 0,
          removed_lines: 0
        }

      when /^diff -[^\s]+ (.+) (.+)$/
        # Traditional unified diff: diff -ruN oldfile newfile
        handle_file(current_file) if current_file
        old_file = $1
        new_file = $2

        # Extract clean filenames from paths like "olddir/file" and "newdir/file"
        old_filename = extract_filename_from_diff_header(old_file)
        new_filename = extract_filename_from_diff_header(new_file)

        # Choose the cleaner filename (prefer one without version directories)
        clean_filename = choose_cleaner_filename(old_filename, new_filename)

        current_file = {
          filename: clean_filename,
          old_filename: nil, # Traditional diff filename differences don't indicate renames
          status: "modified",
          added_lines: 0,
          removed_lines: 0
        }

      when /^--- (.+)$/
        # Traditional unified diff file header (when no diff command line)
        if current_file.nil? && i + 1 < lines.length
          next_line = lines[i + 1]
          if next_line.match(/^\+\+\+ (.+)$/)
            # This is a file header pair
            old_file = $1.strip
            new_file = next_line.match(/^\+\+\+ (.+)$/)[1].strip

            old_filename = extract_filename_from_diff_header(old_file)
            new_filename = extract_filename_from_diff_header(new_file)

            # Choose the cleaner filename (prefer one without version directories)
            clean_filename = choose_cleaner_filename(old_filename, new_filename)

            current_file = {
              filename: clean_filename,
              old_filename: nil, # Traditional diff filename differences don't indicate renames
              status: "modified",
              added_lines: 0,
              removed_lines: 0
            }

            i += 1 # Skip the +++ line since we processed it
          end
        end

      when /^new file mode/
        current_file[:status] = "added" if current_file

      when /^deleted file mode/
        current_file[:status] = "deleted" if current_file

      when /^rename from (.+)$/
        current_file[:old_filename] = $1 if current_file
        current_file[:status] = "renamed"

      when /^rename to (.+)$/
        current_file[:filename] = $1 if current_file

      when /^\+(?![\+\+])/
        # Added line (not +++ header)
        current_file[:added_lines] += 1 if current_file

      when /^\-(?![\-\-])/
        # Removed line (not --- header)
        current_file[:removed_lines] += 1 if current_file
      end

      i += 1
    end

    # Save the last file
    handle_file(current_file) if current_file
  end

  def extract_filename_from_header(header_line)
    # Git format: "a/path/to/file" or "b/path/to/file"
    if header_line.match(/^[ab]\/(.+)$/)
      return $1
    end

    # CVS format: "path/to/file\ttimestamp\trevision" - take first part
    parts = header_line.split(/\s+/)
    parts.first
  end

  def extract_filename_from_diff_header(diff_path)
    # Handle traditional diff paths like:
    # - "postgresql-8.2.1.orig/src/pl/plpython/plpython.c" -> "src/pl/plpython/plpython.c"
    # - "pgstattuple.orig/Makefile" -> "Makefile"
    # - "Makefile.port.old" -> "Makefile.port"
    # - "/dev/null" (for new/deleted files)

    return nil if diff_path == "/dev/null"

    # Remove timestamp if present (unified diff format)
    path_without_timestamp = diff_path.split(/\s+/).first

    # For paths like "project.orig/path/file", extract just "path/file"
    if path_without_timestamp.include?("/")
      parts = path_without_timestamp.split("/")
      # If first part looks like a backup/version dir, skip it
      if parts[0].match(/\.(orig|old|new)$/) || parts[0].include?("-") && parts[0].include?(".")
        return parts[1..-1].join("/")
      end
      # Otherwise keep the full path
      return path_without_timestamp
    end

    # For simple files, remove common version/backup suffixes
    clean_path = path_without_timestamp.gsub(/\.(orig|old|new)$/, "")
    clean_path
  end

  def choose_cleaner_filename(old_filename, new_filename)
    # Choose the filename that doesn't have version directories
    # Prefer shorter paths (less directory nesting from version dirs)
    return new_filename if old_filename.nil?
    return old_filename if new_filename.nil?

    # Count directory separators as a proxy for "cleanliness"
    old_depth = old_filename.count("/")
    new_depth = new_filename.count("/")

    # Prefer the one with fewer directory levels
    if old_depth < new_depth
      old_filename
    elsif new_depth < old_depth
      new_filename
    else
      # Same depth, prefer the new filename (target)
      new_filename
    end
  end

  def handle_file(file_info)
    return unless file_info&.dig(:filename)&.present?

    line_changes = file_info[:added_lines] + file_info[:removed_lines]

    file_info[:line_changes] = line_changes

    @file_handler&.call(file_info)
  end
end
