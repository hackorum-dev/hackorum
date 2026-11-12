module Api
  # The fields a JSON request body may have. `parse` gives the checked
  # values by name, with only the fields that were sent.
  class RequestBody
    class Invalid < StandardError; end
    class UnsupportedMediaType < StandardError; end

    MEDIA_TYPE = "application/json"
    # of a whole request body, checked before it is parsed
    MAX_BYTES = 4.megabytes
    IDS = (1..(2**63 - 1))
    NAME_LIMIT = 100

    Field = Struct.new(:name, :type, :required, :max_length, :max_bytes, :blank, :single_line, keyword_init: true)

    attr_reader :fields

    # required: the message for a body without the field
    def initialize(**fields)
      @fields = fields.to_h { |name, options| [ name.to_s, Field.new(name: name.to_s, blank: true, **options) ] }.freeze
    end

    def names
      fields.keys
    end

    def required
      fields.values.select(&:required).map(&:name)
    end

    def parse(request)
      raise UnsupportedMediaType unless request.media_type == MEDIA_TYPE
      # Rails wraps other JSON values into a hash
      raise Invalid, "the body must be a JSON object" unless request.raw_post.lstrip.start_with?("{")

      data = request.request_parameters
      unknown = data.keys - names
      raise Invalid, "unknown field: #{unknown.first.first(NAME_LIMIT)}" if unknown.any?

      missing = fields.values.find { |field| field.required && !data.key?(field.name) }
      raise Invalid, missing.required if missing

      data.to_h { |name, value| [ name, check(fields.fetch(name), value) ] }
    end

    private

    def check(field, value)
      case field.type
      when :string then string(field, value)
      when :id then id(field, value)
      when :timestamp then timestamp(field, value)
      else raise ArgumentError, "unknown type #{field.type}"
      end
    end

    def string(field, value)
      name = field.name
      raise Invalid, "#{name} must be a string" unless value.is_a?(String)
      raise Invalid, "#{name} is not valid UTF-8" unless value.encoding == Encoding::UTF_8 && value.valid_encoding?
      raise Invalid, "#{name} has a NUL byte" if value.include?("\0")
      raise Invalid, "#{name} is too long, at most #{field.max_bytes} bytes" if field.max_bytes && value.bytesize > field.max_bytes
      raise Invalid, "#{name} is too long, at most #{field.max_length} characters" if field.max_length && value.length > field.max_length
      raise Invalid, "#{name} must not be blank" if !field.blank && value.blank?
      raise Invalid, "#{name} must be a single line" if field.single_line && value.match?(/[[:cntrl:]]/)

      value
    end

    def id(field, value)
      raise Invalid, "#{field.name} must be a positive integer" unless value.is_a?(Integer) && IDS.cover?(value)

      value
    end

    def timestamp(field, value)
      raise Invalid, "#{field.name} must be an ISO 8601 timestamp" unless value.is_a?(String)

      Time.iso8601(value)
    rescue ArgumentError
      raise Invalid, "#{field.name} must be an ISO 8601 timestamp"
    end
  end
end
