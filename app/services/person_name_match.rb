# frozen_string_literal: true

# Fuzzy name helpers for the person duplicate and split reports.
module PersonNameMatch
  module_function

  def norm(name)
    I18n.transliterate(name.to_s).downcase
        .sub(/<.*/, "").gsub(/\*extern\*|["'`]/, "")
        .gsub(/[^a-z0-9@ -]/, " ").squeeze(" ").strip
  end

  def tokens(name)
    name.split(/[ -]+/).reject(&:empty?).to_set
  end

  # "alex shulgin" ~ "alexander shulgin", "mason s" ~ "mason sharp"
  def compatible?(a, b)
    return false if a.empty? || b.empty?

    short, long = [ tokens(a), tokens(b) ].sort_by(&:size)
    short.all? { |t| long.any? { |l| l.start_with?(t) } } ||
      DidYouMean::Levenshtein.distance(a, b) <= 2
  end

  # Mailbox carries one name part plus the start or initial of another
  # ("kyota.horiguchi", "jdavis"). A bare first name ("jeremy@", "chris@") proves nothing.
  def name_in_mailbox?(local, name_tokens)
    name_tokens.to_a.permutation(2).any? do |a, b|
      local.include?(a) && (local.include?(b[0, 4]) || local.include?("#{b[0]}#{a}") || local.include?("#{a}#{b[0]}"))
    end
  end

  # "noname", an address, or the bare mailbox ("lchch1990", "nikhils")
  def junk_name?(name, locals)
    name.empty? || name == "noname" || name.include?("@") ||
      (!name.include?(" ") && locals.include?(name))
  end
end
