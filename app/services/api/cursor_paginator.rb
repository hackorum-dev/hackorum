module Api
  # Keyset pagination. `columns` are our own qualified names from the
  # relation's table, never taken from a request. They must be NOT NULL
  # or listed in `not_null` (rows with NULL there are left out), all sort
  # the same way, and the last one must be unique.
  # An existing order on the relation is replaced.
  # A cursor carries a digest of the columns, the direction and `scope`
  # (what the caller says the list is), and is only taken back with the same.
  # A block given to `page` gets the ordered, limited relation and must
  # return a relation with that limit and order: it may add preloads,
  # selected columns or joins that keep the rows.
  class CursorPaginator
    class InvalidCursor < StandardError; end
    class InvalidLimit < StandardError; end

    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200
    MAX_CURSOR = 500
    YEARS = (1..9999)

    attr_reader :limit

    def initialize(relation, columns:, direction: :desc, limit: nil, cursor: nil, not_null: [], scope: nil)
      @relation = relation
      @columns = columns
      @excluded = Array(not_null).map { |c| excluded_column(c) }
      @attributes = columns.map { |c| attribute_for(c) }
      raise ArgumentError, "#{columns.last} is not unique" unless unique?(@attributes.last)

      @descending = direction.to_sym == :desc
      @signature = Digest::SHA256.hexdigest([ columns.join(","), @descending ? "desc" : "asc", *scope ].join(" ")).first(8)
      @limit = self.class.parse_limit(limit)
      @cursor = cursor.presence
    end

    def self.parse_limit(value)
      return DEFAULT_LIMIT if value.blank?
      raise InvalidLimit, "limit must be a positive integer" unless value.to_s.match?(/\A\d+\z/)

      number = value.to_s.to_i
      raise InvalidLimit, "limit must be a positive integer" if number < 1
      [ number, MAX_LIMIT ].min
    end

    def page
      relation = scoped.limit(limit + 1)
      rows = (block_given? ? checked(yield(relation), relation) : relation).to_a
      more = rows.size > limit
      rows = rows.first(limit)
      [ rows, more ? encode(rows.last) : nil ]
    end

    private

    def own_column(column)
      klass = @relation.klass
      prefix = "#{klass.table_name}."
      definition = klass.columns_hash[column.to_s.delete_prefix(prefix)] if column.to_s.start_with?(prefix)
      raise ArgumentError, "#{column} is not a column of #{klass.table_name}" unless definition

      definition
    end

    def excluded_column(column)
      name = own_column(column).name
      raise ArgumentError, "#{column} is not a sort column" unless @columns.include?(column)

      name
    end

    def checked(result, relation)
      raise ArgumentError, "the block must return a relation" unless result.is_a?(ActiveRecord::Relation)
      raise ArgumentError, "the block changed the limit" unless result.limit_value == relation.limit_value
      raise ArgumentError, "the block changed the order" unless result.order_values == relation.order_values

      result
    end

    def attribute_for(column)
      definition = own_column(column)
      raise ArgumentError, "#{column} is nullable" if definition.null && !@excluded.include?(definition.name)

      definition.name
    end

    def unique?(name)
      klass = @relation.klass
      return true if klass.primary_key == name

      klass.connection.schema_cache.indexes(klass.table_name).any? do |index|
        index.unique && index.where.nil? && index.columns == [ name ]
      end
    end

    def scoped
      keyword = @descending ? "DESC" : "ASC"
      ordered = @excluded.reduce(@relation) { |relation, name| relation.where.not(name => nil) }
      ordered = ordered.reorder(Arel.sql(@columns.map { |c| "#{c} #{keyword}" }.join(", ")))
      return ordered unless @cursor

      table = @relation.klass.arel_table
      row = Arel::Nodes::Grouping.new(@attributes.map { |name| table[name] })
      seen = Arel::Nodes::Grouping.new(decode(@cursor).map { |value| Arel::Nodes.build_quoted(value) })
      ordered.where(@descending ? Arel::Nodes::LessThan.new(row, seen) : Arel::Nodes::GreaterThan.new(row, seen))
    end

    def encode(record)
      values = @attributes.map do |name|
        value = record[name]
        value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) ? value.utc.iso8601(6) : value
      end
      Base64.urlsafe_encode64([ @signature, *values ].to_json, padding: false)
    end

    def decode(cursor)
      raise InvalidCursor, "malformed cursor" unless cursor.is_a?(String) && cursor.length <= MAX_CURSOR

      json = Base64.urlsafe_decode64(cursor).force_encoding(Encoding::UTF_8)
      raise InvalidCursor, "malformed cursor" unless json.valid_encoding?

      signature, *values = JSON.parse(json)
      raise InvalidCursor, "malformed cursor" unless signature.is_a?(String) && values.size == @attributes.size
      raise InvalidCursor, "cursor is from another request" unless signature == @signature

      @attributes.zip(values).map { |name, value| cast(name, value) }
    rescue ArgumentError, TypeError, RangeError, JSON::ParserError
      raise InvalidCursor, "malformed cursor"
    end

    def cast(name, value)
      type = @relation.klass.type_for_attribute(name)
      raise InvalidCursor, "malformed cursor" unless accepts?(type.type, value)

      result = type.cast(value)
      raise InvalidCursor, "malformed cursor" unless valid_result?(type.type, result)

      type.serialize(result)
      result
    end

    def accepts?(kind, value)
      return false if value.is_a?(String) && value.include?("\0")

      case kind
      when :datetime, :date, :string, :text then value.is_a?(String)
      when :integer then value.is_a?(Integer)
      when :float, :decimal then value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
      else value.is_a?(String) || value.is_a?(Integer)
      end
    end

    def valid_result?(kind, result)
      case kind
      when :datetime then result.acts_like?(:time) && YEARS.cover?(result.year)
      when :date then result.is_a?(Date) && YEARS.cover?(result.year)
      else !result.nil?
      end
    end
  end
end
