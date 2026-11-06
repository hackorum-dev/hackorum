module Stats
  module Numbers
    module_function

    def mean(values)
      return 0.0 if values.empty?

      (values.sum.to_f / values.size).round(1)
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    # [[label, count]] in bucket order; the last bucket has no upper bound
    def bucketize(values, buckets)
      counts = buckets.map { |label, _| [ label, 0 ] }.to_h
      values.each do |v|
        label, = buckets.find { |_, max| max.nil? || v <= max }
        counts[label] += 1
      end
      counts.to_a
    end
  end
end
