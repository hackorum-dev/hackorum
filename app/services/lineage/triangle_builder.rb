module Lineage
  class TriangleBuilder
    UNPARSED = { "unparsed" => true }.freeze

    def initialize(topic, patchsets)
      @topic = topic
      @patchsets = patchsets
    end

    def call
      pairs = []
      @patchsets.each_with_index do |later, i|
        @patchsets.first(i).each do |earlier|
          pairs << { later_message_id: later.message.id, earlier_message_id: earlier.message.id,
                     later_ordinal: later.ordinal, earlier_ordinal: earlier.ordinal,
                     metrics: metrics(earlier.parsed, later.parsed) }
        end
      end
      PatchsetPair.transaction do
        PatchsetPair.where(topic_id: @topic.id).delete_all
        rows = pairs.map { |p| p.slice(:later_message_id, :earlier_message_id, :metrics).merge(topic_id: @topic.id) }
        PatchsetPair.insert_all(rows) if rows.any?
      end
      pairs
    end

    private

    def metrics(earlier, later)
      return UNPARSED if earlier.nil? || later.nil?
      DiffMetrics.compare(earlier, later)
    end
  end
end
