# frozen_string_literal: true

class QuotedEmailFormatter
  HEADER_REGEX = /\AOn .+\b(wrote|said|writes):?\z/i
  attr_reader :reference_map
  MESSAGE_ID_PATTERNS = [
    %r{\Ahttps?://(?:www\.)?postgresql\.org/message-id/(?:flat/)?([^?#\s]+)}i,
    %r{\Ahttps?://postgr\.es/m/([^?#\s]+)}i
  ].freeze

  def initialize(body, collapse_quotes: false)
    normalized = body.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
    @lines = normalized.split("\n")
    @collapse_quotes = collapse_quotes
    @reference_map = extract_reference_links(@lines)
  end

  def to_html
    parsed = parse_lines
    ranges = if @collapse_quotes
      quote_section_ranges(parsed)
    else
      trailing_start = find_trailing_quote_start(parsed)
      trailing_start ? [ trailing_start..(parsed.length - 1) ] : []
    end
    build_html(parsed, ranges)
  end

  private

  def parse_lines
    @lines.map do |line|
      if line =~ /^\s*((?:>\s*)+)(.*)$/
        markers = Regexp.last_match(1)
        depth = markers.count(">")
        content = Regexp.last_match(2).sub(/\A\s/, "")
        { depth: depth, text: content, blank: content.strip.empty? }
      else
        { depth: 0, text: line, blank: line.strip.empty? }
      end
    end
  end

  def find_trailing_quote_start(lines)
    last_nonquote_idx = nil

    lines.each_with_index do |line, idx|
      next if line[:blank]
      if line[:depth].zero? && !quote_header?(line[:text])
        last_nonquote_idx = idx
      end
    end

    quote_idx = nil
    lines.each_with_index do |line, idx|
      next unless idx > (last_nonquote_idx || -1)
      if line[:depth].positive?
        quote_idx = idx
        break
      end
    end

    return nil unless quote_idx

    has_nonquote_after = lines.each_with_index.any? do |line, idx|
      idx > quote_idx && line[:depth].zero? && !line[:blank]
    end

    return nil if has_nonquote_after

    header_idx = quote_idx - 1
    if header_idx >= 0 && lines[header_idx][:depth].zero? && quote_header?(lines[header_idx][:text])
      header_idx
    else
      quote_idx
    end
  end

  def quote_header?(text)
    text.strip.match?(HEADER_REGEX)
  end

  # Each section is a maximal run of quoted lines (blank lines between quoted
  # lines stay inside), extended to include an immediately preceding
  # "On ... wrote:" header line.
  def quote_section_ranges(lines)
    ranges = []
    idx = 0
    while idx < lines.length
      unless lines[idx][:depth].positive?
        idx += 1
        next
      end

      start_idx = idx
      last_quote_idx = idx
      scan = idx + 1
      while scan < lines.length && (lines[scan][:depth].positive? || lines[scan][:blank])
        last_quote_idx = scan if lines[scan][:depth].positive?
        scan += 1
      end

      header_idx = start_idx - 1
      if header_idx >= 0 && lines[header_idx][:depth].zero? && quote_header?(lines[header_idx][:text])
        start_idx = header_idx
      end

      ranges << (start_idx..last_quote_idx)
      idx = last_quote_idx + 1
    end
    ranges
  end

  def build_html(lines, collapse_ranges)
    html = +""
    buffer = []
    current_depth = 0
    range_starts = collapse_ranges.to_h { |range| [ range.begin, range ] }
    open_range = nil

    lines.each_with_index do |line, idx|
      if open_range && idx > open_range.end
        flush_buffer(buffer, html, quoted: current_depth.positive?)
        while current_depth.positive?
          html << "</blockquote>\n"
          current_depth -= 1
        end
        html << "</details>\n"
        open_range = nil
      end

      if (range = range_starts[idx])
        flush_buffer(buffer, html, quoted: current_depth.positive?)
        html << %(<details class="quoted-block">\n)
        html << %(<summary>Show quoted text</summary>\n)
        open_range = range
      end

      new_depth = line[:depth]

      if new_depth != current_depth
        flush_buffer(buffer, html, quoted: current_depth.positive?)
        while current_depth > new_depth
          html << "</blockquote>\n"
          current_depth -= 1
        end
        while current_depth < new_depth
          html << "<blockquote>\n"
          current_depth += 1
        end
      end

      if line[:blank]
        buffer << :blank
      else
        buffer << line[:text]
      end
    end

    flush_buffer(buffer, html, quoted: current_depth.positive?)

    while current_depth.positive?
      html << "</blockquote>\n"
      current_depth -= 1
    end

    html << "</details>" if open_range
    html
  end

  def flush_buffer(buffer, html, quoted: false)
    return if buffer.empty?

    paragraphs = []
    current = []

    buffer.each do |line|
      if line == :blank
        unless current.empty?
          paragraphs << current
          current = []
        end
      else
        current << line
      end
    end

    paragraphs << current unless current.empty?

    paragraphs.each do |para|
      if diff_block?(para)
        html << %(<pre class="message-diff"><code>#{ERB::Util.h(para.join("\n"))}</code></pre>\n)
      else
        html << "<p>#{para.map { |l| linkify_line(l, quoted: quoted) }.join('<br>')}</p>\n"
      end
    end

    buffer.clear
  end

  def linkify_line(line, quoted: false)
    if quoted
      return auto_link_html(ERB::Util.h(line))
    end

    if (m = line.strip.match(/^\[(\d+)\]\s*[:\-]?\s*(.*)$/))
      num = m[1]
      rest = @reference_map[num] || m[2]
      label = ERB::Util.h("[#{num}]:")
      body = auto_link_html(ERB::Util.h(rest.strip))
      return %(#{label} <span class="reference-definition" id="ref-#{num}">#{body}</span>)
    end

    escaped = ERB::Util.h(line)
    escaped = auto_link_html(escaped)

    escaped = escaped.gsub(/\[(\d+)\]/) do
      ref_num = Regexp.last_match(1)
      if (ref_text = @reference_map[ref_num])
        inline_reference_html(ref_num, ref_text)
      else
        "[#{ref_num}]"
      end
    end

    escaped
  end

  def inline_reference_html(num, ref_text)
    tooltip = auto_link_html(ERB::Util.h(ref_text))
    %(<span class="inline-reference">[#{num}]<span class="reference-hover">#{tooltip}</span></span>)
  end

  def auto_link_html(text)
    text.gsub(%r{https?://[^\s<]+}) do |url|
      if (mid = extract_message_id_from_url(url))
        href = Rails.application.routes.url_helpers.message_by_id_path(message_id: mid)
      else
        href = url
      end

      escaped_href = ERB::Util.h(href)
      %(<a href="#{escaped_href}" target="_blank" rel="noopener">#{escaped_href}</a>)
    end
  end

  def leading_depth(line)
    return 0 unless line =~ /^\s*((?:>\s*)+)/
    Regexp.last_match(1).count(">")
  end

  def extract_message_id_from_url(url)
    safe_url = url.gsub("+", "%2B")
    decoded = CGI.unescape(safe_url)
    MESSAGE_ID_PATTERNS.each do |pattern|
      if (m = decoded.match(pattern))
        return CGI.unescape(m[1].gsub("+", "%2B"))
      end
    end
    nil
  end

  def extract_reference_links(lines)
    refs = {}
    idx = 0
    while idx < lines.length
      line = lines[idx]
      depth = leading_depth(line)
      if depth.positive?
        idx += 1
        next
      end

      if (m = line.strip.match(/^\[(\d+)\]\s*[:\-]?\s*(.*)$/))
        num = m[1]
        rest = m[2]
        collected = []
        collected << rest.strip unless rest.strip.empty?

        idx += 1
        while idx < lines.length
          nxt = lines[idx]
          nxt_depth = leading_depth(nxt)
          break if nxt_depth.positive?
          if nxt.strip.empty?
            idx += 1
            next if collected.empty?
            break
          end
          break if nxt.strip.match?(/^\[\d+\]\s*[:\-]?/)
          collected << nxt.strip
          idx += 1
        end

        refs[num] = collected.join(" ").strip
        next
      end
      idx += 1
    end
    refs
  end

  def diff_block?(lines)
    return false if lines.empty?

    trimmed = lines.map { |l| l.lstrip }
    return true if trimmed.first.start_with?("diff ")
    return true if trimmed.any? { |l| l.start_with?("--- ", "+++ ", "Index:") }

    marker_flags = trimmed.map { |l| l.start_with?("+", "-", "@") }
    marker_count = marker_flags.count(true)
    has_plus = trimmed.any? { |l| l.start_with?("+") }
    has_minus = trimmed.any? { |l| l.start_with?("-") }
    has_hunk = trimmed.any? { |l| l.start_with?("@@") }
    long_marker_lines = trimmed.any? { |l| l.length > 40 && l.start_with?("+", "-") }
    total = trimmed.length

    # Avoid treating pure "-" lists as diffs unless there is "+" or hunk context.
    requires_plus_context = has_plus || has_hunk

    if marker_count == total && total >= 2 && requires_plus_context
      return true if has_hunk || (has_plus && has_minus) || long_marker_lines
    end

    if total >= 3 && marker_count >= 2 && requires_plus_context
      ratio = marker_count.to_f / total
      longest_run = marker_flags.chunk_while { |a, b| a && b }.map(&:length).max || 0
      return true if ratio >= 0.6
      return true if ratio >= 0.5 && longest_run >= 2 && (has_plus || has_minus)
      return true if long_marker_lines && (has_plus || has_minus)
    end

    false
  end
end
