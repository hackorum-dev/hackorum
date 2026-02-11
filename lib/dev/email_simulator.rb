# frozen_string_literal: true

require "securerandom"
require "faker"

module Dev
  class EmailSimulator
    DEFAULT_EXISTING_ALIAS_PROB = 0.9
    DEFAULT_EXISTING_TOPIC_PROB = 0.9

    def initialize(existing_alias_prob: DEFAULT_EXISTING_ALIAS_PROB, existing_topic_prob: DEFAULT_EXISTING_TOPIC_PROB)
      @existing_alias_prob = existing_alias_prob
      @existing_topic_prob = existing_topic_prob
    end

    def generate_mail(sent_at: Time.current)
      from_alias = pick_alias
      topic, reply_to = pick_topic

      mail = Mail.new
      mail.date = sent_at
      mail.message_id = "<sim-#{SecureRandom.hex}@hackorum.dev>"
      mail.from = "#{from_alias.name} <#{from_alias.email}>"
      mail.to = to_addresses(reply_to, topic)
      mail.subject = subject_for(topic, reply_to)

      if reply_to&.message_id.present?
        mail.in_reply_to = reply_to.message_id
        mail.references = reply_to.message_id
      end

      mail.body = body_for(reply_to)
      mail
    end

    def ingest!(mail)
      EmailIngestor.new.ingest_raw(mail.to_s)
    end

    def generate_and_ingest!(sent_at: Time.current)
      ingest!(generate_mail(sent_at: sent_at))
    end

    private

    def pick_alias
      use_existing = rand < @existing_alias_prob
      existing = Alias.order("RANDOM()").first if use_existing
      return existing if existing

      Alias.create!(
        name: Faker::Name.name,
        email: Faker::Internet.email,
        primary_alias: false,
        verified_at: Time.current
      )
    end

    def pick_topic
      use_existing = rand < @existing_topic_prob
      existing_topic = Topic.joins(:messages).order("RANDOM()").first if use_existing
      return [ existing_topic, existing_topic&.messages&.order("RANDOM()")&.first ] if existing_topic

      [ nil, nil ]
    end

    def subject_for(topic, reply_to)
      return "Re: #{topic.title}" if topic && reply_to
      return topic.title if topic
      Faker::Hacker.say_something_smart.capitalize
    end

    def body_for(reply_to)
      paragraphs = Faker::Lorem.paragraphs(number: rand(2..5))
      body = paragraphs.join("\n\n")
      if reply_to
        quoted = reply_to.body.to_s.lines.first(4).map { |l| "> #{l.chomp}" }.join("\n")
        body = "#{quoted}\n\n#{body}"
      end
      body
    end

    def to_addresses(reply_to, topic)
      recipients = []
      if reply_to
        recipients << reply_to.sender.email
      elsif topic
        recipients << topic.creator.email
      else
        recipients << Faker::Internet.email
      end
      recipients
    end
  end
end
