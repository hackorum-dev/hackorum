# Message bodies without the quoted parts.
module MessageBodyText
  QUOTE_RE = /\A>/
  ORIGINAL_RE = /\A-----Original Message-----/
  ATTRIBUTION_START_RE = /\A\s*On .{0,200}\s*\z/
  ATTRIBUTION_END_RE = /\A.{0,200}wrote:\s*\z/
  ATTRIBUTION_RE = /\A\s*On .{0,200}wrote:\s*\z/

  # the lineage prompt is built from this: a change here changes its input
  def self.strip_quotes(body)
    lines = []
    all = body.to_s.scrub.lines
    all.each_with_index do |l, i|
      break if l.match?(ORIGINAL_RE)
      next if l.match?(QUOTE_RE) || l.match?(ATTRIBUTION_RE)
      next if l.match?(ATTRIBUTION_START_RE) && all[i + 1]&.match?(ATTRIBUTION_END_RE)
      next if i > 0 && all[i - 1].match?(ATTRIBUTION_START_RE) && l.match?(ATTRIBUTION_END_RE)
      lines << l
    end
    lines.join.gsub(/\n{3,}/, "\n\n")
  end
end
