require "mail"

module Outgoing
  class RecipientResolver
    class MissingPostAddressError   < StandardError; end
    class MissingDevOverrideError   < StandardError; end
    class RealListAddressInDevError < StandardError; end

    Recipients = Struct.new(:to, :cc, keyword_init: true) do
      def all = to + cc
    end

    FAKE_ADDRESS_SUFFIX = "@unknown.user"

    def self.for(draft)
      return Recipients.new(to: [ dev_override ], cc: []) if !Rails.env.production? || Hackorum.staging?

      list = draft.topic.mailing_lists.first
      raise MissingPostAddressError if list.nil? || list.post_address.blank?

      parent = draft.reply_to_message
      seen   = Set.new([ draft.sender_alias.email.to_s.strip.downcase ])

      # both picks share seen, so cc never repeats to
      to = pick(seen, [ parent.sender ])
      cc = pick(seen, [ list.post_address ] + parent.mentioned_aliases.order("mentions.id").to_a)
      to = cc.shift(1) if to.empty?

      Recipients.new(to: to, cc: cc)
    end

    def self.pick(seen, entries)
      entries.filter_map do |entry|
        email = (entry.respond_to?(:email) ? entry.email : entry).to_s.strip
        next if email.blank?
        next if email.downcase.end_with?(FAKE_ADDRESS_SUFFIX)
        next unless seen.add?(email.downcase)
        format_address(entry, email)
      end
    end

    def self.format_address(entry, email)
      name = entry.respond_to?(:name) ? entry.name.to_s.strip : ""
      return email if name.blank? || (entry.respond_to?(:noname?) ? entry.noname? : name == "Noname")
      addr = Mail::Address.new
      addr.address = email
      addr.display_name = name
      # scraped data holds garbage addresses; keep raw email if mail gem mangles it
      addr.address == email ? addr.format : email
    rescue Mail::Field::ParseError
      email
    end

    def self.dev_override
      override = ENV["HACKORUM_DEV_REPLY_TO"]
      raise MissingDevOverrideError if override.blank?
      if MailingList.where("lower(post_address) = lower(?)", override).exists?
        raise RealListAddressInDevError
      end
      override
    end

    private_class_method :pick, :format_address, :dev_override
  end
end
