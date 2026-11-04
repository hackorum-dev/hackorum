module Topics
  class ParticipantActivity
    TOP = 5
    BUCKETS = [
      [ :committers, "Committers", %w[core_team committer] ],
      [ :major, "Major", %w[major_contributor] ],
      [ :significant, "Significant", %w[significant_contributor] ],
      [ :others, "Others", [] ]
    ].freeze

    Bucket = Struct.new(:key, :label, :people, :messages, keyword_init: true)

    def initialize(participants:, messages:, message_numbers:, viewer_person_id:)
      @participants = participants
      @messages = messages
      @message_numbers = message_numbers
      @viewer_person_id = viewer_person_id
    end

    def count = @participants.size
    def top = @participants.first(TOP)

    def total_messages
      @participants.sum { |p| p[:message_count].to_i }
    end

    def buckets
      @buckets ||= BUCKETS.map do |key, label, _|
        members = @participants.select { |p| bucket_for(p) == key }
        Bucket.new(key: key, label: label, people: members.size, messages: members.sum { |p| p[:message_count].to_i })
      end
    end

    def strip_label
      "Messages by role: " + buckets.map { |b| "#{b.label} #{b.messages}" }.join(", ")
    end

    def viewer
      return nil unless @viewer_person_id
      return nil if top.any? { |p| p[:person]&.id == @viewer_person_id }
      @participants.find { |p| p[:person]&.id == @viewer_person_id }
    end

    def viewer_last_number
      return nil unless @viewer_person_id
      message = @messages.reverse_each.find { |m| m.sender_person_id == @viewer_person_id }
      message && @message_numbers[message.id]
    end

    def rest
      pinned = viewer
      @participants.drop(TOP).reject { |p| p.equal?(pinned) }
    end

    def last_committer_message
      ids = @participants.select { |p| bucket_for(p) == :committers }.filter_map { |p| p[:person]&.id }.to_set
      message = @messages.reverse_each.find { |m| ids.include?(m.sender_person_id) }
      message && { number: @message_numbers[message.id], message: message }
    end

    def bucket_label(participant)
      key = bucket_for(participant)
      BUCKETS.find { |k, _, _| k == key }[1]
    end

    private

    def bucket_for(participant)
      types = participant[:person]&.contributor_membership_types || []
      BUCKETS.find { |_, _, wanted| (wanted & types).any? }&.first || :others
    end
  end
end
