# frozen_string_literal: true

module Api
  # View model of an OpenAPI document, for a page people read.
  class Reference
    PATH = Rails.root.join("docs/api/openapi.yaml")
    METHODS = %w[get put post delete options head patch trace].freeze
    MAX_DEPTH = 12
    LIMITS = {
      "minimum" => "min", "maximum" => "max", "exclusiveMinimum" => "above", "exclusiveMaximum" => "below",
      "minLength" => "min length", "maxLength" => "max length", "minItems" => "min items", "maxItems" => "max items",
      "multipleOf" => "multiple of", "pattern" => "pattern"
    }.freeze
    FLAGS = { "deprecated" => "deprecated", "readOnly" => "read only", "writeOnly" => "write only" }.freeze

    Link = Struct.new(:name, :anchor)
    Tag = Struct.new(:name, :anchor, :description, :operations, keyword_init: true)
    Operation = Struct.new(:method, :path, :id, :anchor, :tag, :summary, :description, :deprecated, :token,
                           :parameters, :request_body, :responses, keyword_init: true)
    Parameter = Struct.new(:name, :location, :required, :description, :schema, keyword_init: true)
    Body = Struct.new(:description, :required, :contents, keyword_init: true)
    Content = Struct.new(:media_type, :schema, keyword_init: true)
    Response = Struct.new(:status, :description, :shared, :headers, :contents, keyword_init: true)
    Header = Struct.new(:name, :description, :schema, keyword_init: true)
    Schema = Struct.new(:name, :anchor, :node, keyword_init: true)
    SharedResponse = Struct.new(:name, :anchor, :response, keyword_init: true)

    Node = Struct.new(:name, :required, :type, :description, :enum, :notes, :fields, keyword_init: true) do
      def type_text
        type.map { |part| part.is_a?(Link) ? part.name : part }.join
      end

      def detail?
        description.present? || enum.present? || notes.any? || fields.any?
      end
    end

    attr_reader :title, :version, :description, :base_url, :tags, :operations, :schemas, :responses

    class << self
      def current
        return load_file if Rails.env.development?

        @current ||= load_file
      end

      def load_file(path = PATH)
        text = File.read(path)
        new(YAML.safe_load(text), digest: Digest::SHA256.hexdigest(text))
      end

      def anchor(prefix, name)
        "#{prefix}-#{name.to_s.gsub(/[^A-Za-z0-9_.-]/, '-')}"
      end
    end

    def initialize(document, digest: nil)
      @document = document.is_a?(Hash) ? document : {}
      @digest = digest
      info = hash(@document["info"])
      @title = info["title"].presence&.to_s || "API"
      @version = info["version"].presence&.to_s
      @description = text(info["description"])
      @base_url = text(hash(Array.wrap(@document["servers"]).first)["url"])
      @raw_schemas = hash(hash(@document["components"])["schemas"])
      @schemas = @raw_schemas.sort_by { |name, _| name.to_s.downcase }.map do |name, schema|
        Schema.new(name: name.to_s, anchor: self.class.anchor("schema", name), node: describe(schema))
      end
      @responses = hash(hash(@document["components"])["responses"]).map do |name, raw|
        SharedResponse.new(name: name.to_s, anchor: self.class.anchor("response", name),
                           response: response("", raw).tap { |entry| entry.shared = nil })
      end
      @operations = build_operations
      @tags = build_tags
    end

    def digest
      @digest ||= Digest::SHA256.hexdigest(@document.to_json)
    end

    private

    def hash(value)
      value.is_a?(Hash) ? value : {}
    end

    def text(value)
      value.is_a?(String) ? value.presence : nil
    end

    def build_operations
      taken = Hash.new(0)
      hash(@document["paths"]).flat_map do |path, item|
        hash(item).filter_map do |method, raw|
          next unless METHODS.include?(method) && raw.is_a?(Hash)

          operation(method, path.to_s, raw, item, taken)
        end
      end
    end

    def operation(method, path, raw, item, taken)
      id = text(raw["operationId"])
      anchor = self.class.anchor("op", id || "#{method}#{path}".gsub(/[^A-Za-z0-9]+/, "-").gsub(/\A-|-\z/, ""))
      count = taken[anchor] += 1
      anchor = "#{anchor}-#{count}" if count > 1
      Operation.new(
        method: method.upcase, path: path, id: id, anchor: anchor,
        summary: text(raw["summary"]), description: text(raw["description"]), deprecated: raw["deprecated"] == true,
        token: token(raw), tag: Array.wrap(raw["tags"]).grep(String).first,
        parameters: parameters(item["parameters"], raw["parameters"]),
        request_body: request_body(raw["requestBody"]),
        responses: hash(raw["responses"]).map { |status, entry| response(status.to_s, entry) }
      )
    end

    def build_tags
      declared = Array.wrap(@document["tags"]).grep(Hash).to_h { |tag| [ tag["name"].to_s, text(tag["description"]) ] }
      grouped = @operations.group_by(&:tag)
      names = declared.keys | grouped.keys.compact
      names << nil if grouped.key?(nil)
      names.filter_map do |name|
        next unless grouped.key?(name)

        Tag.new(name: name || "Other", anchor: self.class.anchor("tag", name || "Other"),
                description: declared[name], operations: grouped[name])
      end
    end

    def token(raw)
      list = raw.key?("security") ? raw["security"] : @document["security"]
      list = Array.wrap(list).grep(Hash)
      return :none if list.none?(&:present?)

      list.any?(&:empty?) ? :optional : :required
    end

    def parameters(shared, own)
      merged = {}
      (list(shared) + list(own)).each do |entry|
        raw, name = resolve(entry)
        next unless raw

        param = parameter(raw, name)
        merged[[ param.name, param.location ]] = param
      end
      merged.values
    end

    def list(value)
      value.is_a?(Array) ? value : []
    end

    def parameter(raw, fallback)
      schema = raw["schema"] || hash(hash(raw["content"]).values.first)["schema"]
      node = describe(schema)
      Parameter.new(name: (raw["name"] || fallback).to_s, location: text(raw["in"]), required: raw["required"] == true,
                    description: text(raw["description"]) || node.description, schema: node)
    end

    def request_body(entry)
      raw, = resolve(entry)
      return if raw.blank?

      Body.new(description: text(raw["description"]), required: raw["required"] == true, contents: contents(raw["content"]))
    end

    def response(status, entry)
      raw, name = resolve(entry)
      raw ||= {}
      shared = entry.is_a?(Hash) && entry["$ref"].to_s.start_with?("#/components/responses/") && name
      Response.new(
        status: status, description: text(raw["description"]),
        shared: shared ? Link.new(name, self.class.anchor("response", name)) : nil,
        headers: hash(raw["headers"]).filter_map { |header, value| header(header.to_s, value) },
        contents: contents(raw["content"])
      )
    end

    def header(name, entry)
      raw, = resolve(entry)
      raw ||= {}
      node = describe(raw["schema"])
      Header.new(name: name, description: text(raw["description"]) || node.description, schema: node)
    end

    def contents(value)
      hash(value).map do |media_type, raw|
        schema = hash(raw)["schema"]
        Content.new(media_type: media_type.to_s, schema: schema.nil? ? nil : describe(schema))
      end
    end

    # follows refs of things that are not schemas; the last name of the first ref is kept
    def resolve(entry)
      return unless entry.is_a?(Hash)

      name = nil
      seen = []
      while entry.is_a?(Hash) && entry["$ref"].is_a?(String)
        ref = entry["$ref"]
        name ||= unescape(ref.split("/").last.to_s)
        target = seen.include?(ref) || seen.size >= MAX_DEPTH ? nil : pointer(ref)
        return [ {}, name ] unless target.is_a?(Hash)

        seen << ref
        entry = target.merge(entry.except("$ref"))
      end
      [ entry, name ]
    end

    def pointer(ref)
      return unless ref.start_with?("#/")

      ref.delete_prefix("#/").split("/").reduce(@document) do |node, segment|
        key = unescape(segment)
        case node
        when Hash then node[key]
        when Array then key.match?(/\A\d+\z/) ? node[key.to_i] : nil
        end
      end
    end

    def unescape(segment)
      CGI.unescape(segment.gsub("+", "%2B")).gsub("~1", "/").gsub("~0", "~")
    end

    def schema_link(ref)
      name = ref[%r{\A#/components/schemas/([^/]+)\z}, 1]
      return unless name

      name = unescape(name)
      Link.new(name, self.class.anchor("schema", name)) if @raw_schemas.key?(name)
    end

    def blank_node(parts, description = nil)
      Node.new(type: parts, description: description, enum: nil, notes: [], fields: [], required: false)
    end

    def describe(schema, trail = [])
      return blank_node([ "any" ]) unless schema.is_a?(Hash)
      return reference(schema, trail) if schema["$ref"].is_a?(String)

      key = %w[oneOf anyOf allOf].find { |name| schema[name].is_a?(Array) && schema[name].any? }
      node = case key
      when nil then plain(schema, trail)
      when "allOf" then intersection(schema, trail)
      else union(schema, key, trail)
      end
      node.description = text(schema["description"]) || node.description
      node.enum = schema["enum"].map { |value| display(value) } if schema["enum"].is_a?(Array)
      node.notes = notes(schema) + node.notes
      node
    end

    def reference(schema, trail)
      ref = schema["$ref"]
      description = text(schema["description"])
      link = schema_link(ref)
      return blank_node([ link ], description) if link

      target = trail.include?(ref) || trail.size >= MAX_DEPTH ? nil : pointer(ref)
      return blank_node([ unescape(ref.split("/").last.to_s) ], description) unless target.is_a?(Hash)

      describe(target, trail + [ ref ]).tap { |node| node.description = description if description }
    end

    def union(schema, key, trail)
      variants = schema[key].map { |variant| describe(variant, trail) }
      nulls, rest = variants.partition { |variant| variant.type == [ "null" ] }
      node = rest.size == 1 ? rest.first : choice(key == "oneOf" ? "one of: " : "any of: ", rest)
      node.type = rest.empty? ? [ "null" ] : node.type + (nulls.any? ? [ " or null" ] : [])
      node.fields = properties(schema, trail) + node.fields
      node
    end

    def intersection(schema, trail)
      variants = schema["allOf"].map { |variant| describe(variant, trail) }
      node = variants.size == 1 ? variants.first : blank_node([ "all of: ", *join(variants.map(&:type), ", ") ])
      if variants.size > 1
        node.fields = variants.flat_map(&:fields)
        node.description = variants.filter_map(&:description).first
      end
      node.fields = properties(schema, trail) + node.fields
      node
    end

    def choice(label, variants)
      node = blank_node([ label, *join(variants.map(&:type), ", ") ])
      node.fields = variants.each_with_index.filter_map do |variant, index|
        variant.tap { |entry| entry.name = "option #{index + 1}" } if variant.detail?
      end
      node
    end

    def plain(schema, trail)
      types = types(schema)
      nullable = types.delete("null")
      node = blank_node([])
      names = types.map { |type| type_parts(type, schema, node, trail) }
      node.type = join(names, " or ")
      node.type = [ nullable ? "null" : "any" ] if node.type.empty?
      node.type += [ " or null" ] if nullable && names.any?
      node
    end

    def types(schema)
      types = case schema["type"]
      when String then [ schema["type"] ]
      when Array then schema["type"].grep(String)
      else []
      end
      return types if types.any?
      return [ "object" ] if schema["properties"].is_a?(Hash) || schema["additionalProperties"].is_a?(Hash)

      schema["items"].is_a?(Hash) ? [ "array" ] : []
    end

    def type_parts(type, schema, node, trail)
      case type
      when "array" then array_parts(schema, node, trail)
      when "object" then object_parts(schema, node, trail)
      else [ text(schema["format"]) ? "#{type} (#{schema['format']})" : type ]
      end
    end

    def array_parts(schema, node, trail)
      return [ "array" ] unless schema["items"].is_a?(Hash)

      item = describe(schema["items"], trail)
      absorb(node, item)
      compound = item.type.any? { |part| part.is_a?(String) && part.match?(/ or |: /) }
      [ "array of ", *(compound ? [ "(", *item.type, ")" ] : item.type) ]
    end

    def object_parts(schema, node, trail)
      node.fields = properties(schema, trail)
      extra = schema["additionalProperties"]
      return [ "object" ] unless extra.is_a?(Hash)

      value = describe(extra, trail)
      if node.fields.any?
        node.fields += [ value.tap { |entry| entry.name = "(any other field)" } ]
        return [ "object" ]
      end
      absorb(node, value)
      [ "map of string to ", *value.type ]
    end

    def absorb(node, inner)
      node.fields = inner.fields
      node.enum = inner.enum
      node.notes = inner.notes
      node.description = inner.description
    end

    def properties(schema, trail)
      required = list(schema["required"])
      hash(schema["properties"]).map do |name, value|
        describe(value, trail).tap do |node|
          node.name = name.to_s
          node.required = required.include?(name)
        end
      end
    end

    def notes(schema)
      notes = LIMITS.filter_map { |key, label| [ label, display(schema[key]) ] if scalar?(schema[key]) }
      notes << [ "always", display(schema["const"]) ] if schema.key?("const")
      notes << [ "default", display(schema["default"]) ] if schema.key?("default")
      examples = (schema.key?("example") ? [ schema["example"] ] : []) + list(schema["examples"])
      notes.concat(examples.map { |value| [ "example", display(value) ] })
      notes.concat(FLAGS.filter_map { |key, label| [ label, nil ] if schema[key] == true })
      notes << [ "other fields allowed", nil ] if schema["additionalProperties"] == true
      notes
    end

    def scalar?(value)
      value.is_a?(String) || value.is_a?(Numeric)
    end

    def display(value)
      case value
      when String then value
      when nil then "null"
      else value.to_json
      end
    end

    def join(lists, separator)
      lists.flat_map.with_index { |parts, index| index.zero? ? parts : [ separator, *parts ] }
    end
  end
end
