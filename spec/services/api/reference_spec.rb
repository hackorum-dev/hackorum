# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::Reference do
  def reference(overrides = {})
    described_class.new({ "openapi" => "3.1.0", "info" => { "title" => "T" } }.merge(overrides))
  end

  def schema_node(schema, others = {})
    reference("components" => { "schemas" => others.merge("Subject" => schema) })
      .schemas.find { |entry| entry.name == "Subject" }.node
  end

  def field(node, name)
    node.fields.find { |entry| entry.name == name }
  end

  let(:pet) { { "type" => "object", "properties" => { "name" => { "type" => "string" } } } }

  describe "document" do
    it "has title, version, description and the base path" do
      ref = reference("info" => { "title" => "Pets", "version" => "2", "description" => "About `pets`" },
                      "servers" => [ { "url" => "/api/v9" } ])

      expect(ref.title).to eq("Pets")
      expect(ref.version).to eq("2")
      expect(ref.description).to eq("About `pets`")
      expect(ref.base_url).to eq("/api/v9")
    end

    it "takes an empty document" do
      ref = described_class.new({})

      expect(ref.title).to eq("API")
      expect(ref.tags).to eq([])
      expect(ref.schemas).to eq([])
      expect(ref.responses).to eq([])
    end

    it "takes a document of the wrong shape" do
      ref = described_class.new({ "paths" => { "/a" => "x", "/b" => { "get" => "y", "post" => { "responses" => [ 1 ], "parameters" => "p" } } },
                                  "tags" => "none", "components" => { "schemas" => { "A" => true, "B" => nil, "C" => [ 1 ] } },
                                  "security" => "yes" })

      expect(ref.operations.map(&:method)).to eq(%w[POST])
      expect(ref.schemas.map(&:name)).to eq(%w[A B C])
      expect(ref.schemas.map { |entry| entry.node.type_text }.uniq).to eq(%w[any])
    end
  end

  describe "tags and operations" do
    let(:paths) do
      {
        "/b" => {
          "get" => { "operationId" => "listB", "tags" => [ "Second" ], "summary" => "List b" },
          "post" => { "operationId" => "makeB", "tags" => [ "First", "Second" ], "description" => "Make b" }
        },
        "/a" => {
          "summary" => "not an operation",
          "delete" => { "operationId" => "dropA" },
          "get" => { "tags" => [ "Undeclared" ] }
        }
      }
    end
    let(:ref) do
      reference("tags" => [ { "name" => "First", "description" => "One" }, { "name" => "Second" }, { "name" => "Empty" } ],
                "paths" => paths)
    end

    it "groups operations by their first tag in document order, untagged ones under Other" do
      expect(ref.tags.map(&:name)).to eq(%w[First Second Undeclared Other])
      expect(ref.tags.map { |tag| tag.operations.map { |op| [ op.method, op.path ] } }).to eq(
        [ [ [ "POST", "/b" ] ], [ [ "GET", "/b" ] ], [ [ "GET", "/a" ] ], [ [ "DELETE", "/a" ] ] ]
      )
      expect(ref.tags.first.description).to eq("One")
      expect(ref.tags.map(&:anchor)).to eq(%w[tag-First tag-Second tag-Undeclared tag-Other])
    end

    it "gives every operation an anchor, from the operationId when there is one" do
      expect(ref.operations.map(&:anchor)).to eq(%w[op-listB op-makeB op-dropA op-get-a])
      expect(ref.operations.map(&:summary)).to eq([ "List b", nil, nil, nil ])
      expect(ref.operations.second.description).to eq("Make b")
    end

    it "keeps anchors apart when two operations would get the same one" do
      ref = reference("paths" => { "/a" => { "get" => { "operationId" => "same" } }, "/b" => { "get" => { "operationId" => "same" } } })

      expect(ref.operations.map(&:anchor)).to eq(%w[op-same op-same-2])
    end
  end

  describe "token" do
    def token(global, operation = :unset)
      op = operation == :unset ? {} : { "security" => operation }
      doc = { "paths" => { "/x" => { "get" => op } } }
      doc["security"] = global unless global == :unset
      reference(doc).operations.first.token
    end

    it "is optional when an empty requirement stands next to a scheme" do
      expect(token([ {}, { "bearer" => [] } ])).to eq(:optional)
    end

    it "is required with schemes only" do
      expect(token([ { "bearer" => [] } ])).to eq(:required)
    end

    it "is not used without requirements" do
      expect(token(:unset)).to eq(:none)
      expect(token([])).to eq(:none)
      expect(token([ {} ])).to eq(:none)
    end

    it "takes the operation's own list over the global one" do
      expect(token([ {}, { "bearer" => [] } ], [ { "bearer" => [] } ])).to eq(:required)
      expect(token([ { "bearer" => [] } ], [])).to eq(:none)
      expect(token(:unset, [ {}, { "bearer" => [] } ])).to eq(:optional)
    end
  end

  describe "parameters" do
    let(:components) do
      {
        "parameters" => {
          "limit" => { "name" => "limit", "in" => "query", "description" => "Page size",
                       "schema" => { "type" => "integer", "minimum" => 1, "maximum" => 200, "default" => 50 } },
          "alias" => { "$ref" => "#/components/parameters/limit" },
          "loop" => { "$ref" => "#/components/parameters/loop" }
        },
        "schemas" => { "Order" => { "type" => "string", "enum" => %w[asc desc] } }
      }
    end

    def parameters(list, path_level = nil)
      item = { "get" => { "parameters" => list } }
      item["parameters"] = path_level if path_level
      reference("paths" => { "/x/{id}" => item }, "components" => components).operations.first.parameters
    end

    it "resolves refs, through a chain" do
      limit = parameters([ { "$ref" => "#/components/parameters/alias" } ]).first

      expect(limit.name).to eq("limit")
      expect(limit.location).to eq("query")
      expect(limit.required).to be(false)
      expect(limit.description).to eq("Page size")
      expect(limit.schema.type_text).to eq("integer")
      expect(limit.schema.notes).to eq([ [ "min", "1" ], [ "max", "200" ], [ "default", "50" ] ])
    end

    it "has type, enum, pattern and limits" do
      list = parameters([
        { "name" => "id", "in" => "path", "required" => true, "schema" => { "type" => "string", "pattern" => "^a+$", "maxLength" => 9 } },
        { "name" => "state", "in" => "query", "schema" => { "type" => "string", "enum" => [ "open", "closed", nil ] } },
        { "name" => "order", "in" => "query", "schema" => { "$ref" => "#/components/schemas/Order" } },
        { "name" => "bare", "in" => "header" },
        { "name" => "json", "in" => "query", "content" => { "application/json" => { "schema" => { "type" => "array", "items" => { "type" => "integer" } } } } }
      ])

      expect(list.map(&:name)).to eq(%w[id state order bare json])
      expect(list.first.required).to be(true)
      expect(list.first.schema.notes).to eq([ [ "max length", "9" ], [ "pattern", "^a+$" ] ])
      expect(list.second.schema.enum).to eq(%w[open closed null])
      expect(list.third.schema.type_text).to eq("Order")
      expect(list.third.schema.type.first.anchor).to eq("schema-Order")
      expect(list.fourth.schema.type_text).to eq("any")
      expect(list.fifth.schema.type_text).to eq("array of integer")
    end

    it "merges the parameters of the path, the operation's own win" do
      list = parameters([ { "name" => "id", "in" => "path", "description" => "own" }, { "name" => "q", "in" => "query" } ],
                        [ { "name" => "id", "in" => "path", "description" => "shared" }, { "name" => "id", "in" => "query" } ])

      expect(list.map { |param| [ param.name, param.location, param.description ] }).to eq(
        [ [ "id", "path", "own" ], [ "id", "query", nil ], [ "q", "query", nil ] ]
      )
    end

    it "survives a ref that goes nowhere or in a circle" do
      list = parameters([ { "$ref" => "#/components/parameters/none" }, { "$ref" => "#/components/parameters/loop" },
                          { "$ref" => "other.yaml#/x" }, "junk" ])

      expect(list.map(&:name)).to eq(%w[none loop x])
      expect(list.map { |param| param.schema.type_text }.uniq).to eq(%w[any])
    end
  end

  describe "request body and responses" do
    let(:components) do
      {
        "schemas" => { "Pet" => pet, "Error" => { "type" => "object" } },
        "headers" => { "Limit" => { "description" => "Per minute", "schema" => { "type" => "integer" } } },
        "requestBodies" => { "PetBody" => { "required" => true, "description" => "A pet",
                                            "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Pet" } } } } },
        "responses" => {
          "Failure" => { "description" => "It failed", "headers" => { "Limit" => { "$ref" => "#/components/headers/Limit" } },
                         "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Error" } } } }
        }
      }
    end
    let(:operation) do
      {
        "requestBody" => { "$ref" => "#/components/requestBodies/PetBody" },
        "responses" => {
          "200" => {
            "description" => "Fine",
            "headers" => { "Limit" => { "$ref" => "#/components/headers/Limit" }, "Location" => { "schema" => { "type" => "string" } } },
            "content" => {
              "application/json" => { "schema" => { "type" => "object", "required" => [ "data" ],
                                                    "properties" => { "data" => { "type" => "array", "items" => { "$ref" => "#/components/schemas/Pet" } } } } },
              "text/plain" => { "schema" => { "type" => "string" } },
              "image/png" => {}
            }
          },
          204 => { "description" => "Nothing" },
          "default" => { "$ref" => "#/components/responses/Failure" }
        }
      }
    end
    let(:ref) { reference("paths" => { "/pets" => { "post" => operation } }, "components" => components) }
    let(:op) { ref.operations.first }

    it "resolves the request body" do
      body = op.request_body

      expect(body.required).to be(true)
      expect(body.description).to eq("A pet")
      expect(body.contents.map(&:media_type)).to eq(%w[application/json])
      expect(body.contents.first.schema.type_text).to eq("Pet")
      expect(body.contents.first.schema.fields).to eq([])
    end

    it "has no request body when the operation has none" do
      expect(reference("paths" => { "/x" => { "get" => {} } }).operations.first.request_body).to be_nil
    end

    it "lists responses in document order with headers, media types and schemas" do
      expect(op.responses.map(&:status)).to eq(%w[200 204 default])

      fine = op.responses.first
      expect(fine.description).to eq("Fine")
      expect(fine.shared).to be_nil
      expect(fine.headers.map { |header| [ header.name, header.description, header.schema.type_text ] }).to eq(
        [ [ "Limit", "Per minute", "integer" ], [ "Location", nil, "string" ] ]
      )
      expect(fine.contents.map(&:media_type)).to eq(%w[application/json text/plain image/png])
      expect(fine.contents.first.schema.type_text).to eq("object")
      expect(field(fine.contents.first.schema, "data").type_text).to eq("array of Pet")
      expect(field(fine.contents.first.schema, "data").required).to be(true)
      expect(fine.contents.third.schema).to be_nil

      expect(op.responses.second.contents).to eq([])
    end

    it "resolves a shared response and says which one it is" do
      failure = op.responses.last

      expect(failure.description).to eq("It failed")
      expect(failure.shared.name).to eq("Failure")
      expect(failure.shared.anchor).to eq("response-Failure")
      expect(failure.headers.map(&:name)).to eq(%w[Limit])
      expect(failure.contents.first.schema.type_text).to eq("Error")
    end

    it "lists the shared responses of the document" do
      expect(ref.responses.map(&:name)).to eq(%w[Failure])
      expect(ref.responses.first.anchor).to eq("response-Failure")
      expect(ref.responses.first.response.description).to eq("It failed")
    end
  end

  describe "schemas" do
    it "lists every schema by name with an anchor" do
      ref = reference("components" => { "schemas" => { "Zebra" => pet, "Ant" => pet, "odd name/<x>" => pet } })

      expect(ref.schemas.map(&:name)).to eq([ "Ant", "odd name/<x>", "Zebra" ])
      expect(ref.schemas.map(&:anchor)).to eq(%w[schema-Ant schema-odd-name--x- schema-Zebra])
    end

    it "lists the fields of an object with type, required flag and description" do
      node = schema_node({ "type" => "object", "description" => "A thing", "required" => [ "id" ],
                           "properties" => { "id" => { "type" => "integer", "description" => "Its id" },
                                             "at" => { "type" => "string", "format" => "date-time" } } })

      expect(node.type_text).to eq("object")
      expect(node.description).to eq("A thing")
      expect(node.fields.map { |entry| [ entry.name, entry.type_text, entry.required, entry.description ] }).to eq(
        [ [ "id", "integer", true, "Its id" ], [ "at", "string (date-time)", false, nil ] ]
      )
    end

    it "names nullable types, in the array form and as a lone null" do
      node = schema_node({ "type" => "object", "properties" => {
        "a" => { "type" => [ "string", "null" ] },
        "b" => { "type" => "null" },
        "c" => { "type" => [ "integer", "string" ] },
        "d" => { "type" => [ "string", "null" ], "format" => "date-time" }
      } })

      expect(node.fields.map(&:type_text)).to eq([ "string or null", "null", "integer or string", "string (date-time) or null" ])
    end

    it "links a ref and does not expand it" do
      node = schema_node({ "type" => "object", "properties" => {
        "pet" => { "$ref" => "#/components/schemas/Pet", "description" => "The pet" }
      } }, "Pet" => pet)
      entry = field(node, "pet")

      expect(entry.type_text).to eq("Pet")
      expect(entry.type).to eq([ described_class::Link.new("Pet", "schema-Pet") ])
      expect(entry.fields).to eq([])
      expect(entry.description).to eq("The pet")
    end

    it "names a nullable ref and a choice of several" do
      node = schema_node({ "type" => "object", "properties" => {
        "a" => { "oneOf" => [ { "$ref" => "#/components/schemas/Pet" }, { "type" => "null" } ], "description" => "Maybe" },
        "b" => { "oneOf" => [ { "$ref" => "#/components/schemas/Pet" }, { "$ref" => "#/components/schemas/Toy" } ] },
        "c" => { "anyOf" => [ { "$ref" => "#/components/schemas/Pet" }, { "type" => "string" }, { "type" => "null" } ] },
        "d" => { "allOf" => [ { "$ref" => "#/components/schemas/Pet" } ] },
        "e" => { "allOf" => [ { "$ref" => "#/components/schemas/Pet" }, { "type" => "object", "properties" => { "extra" => { "type" => "boolean" } } } ] }
      } }, "Pet" => pet, "Toy" => pet)

      expect(node.fields.map(&:type_text)).to eq(
        [ "Pet or null", "one of: Pet, Toy", "any of: Pet, string or null", "Pet", "all of: Pet, object" ]
      )
      expect(field(node, "a").description).to eq("Maybe")
      expect(field(node, "a").type.grep(described_class::Link).map(&:anchor)).to eq(%w[schema-Pet])
      expect(field(node, "b").type.grep(described_class::Link).map(&:name)).to eq(%w[Pet Toy])
      expect(field(node, "e").fields.map(&:name)).to eq(%w[extra])
    end

    it "shows the inline options of a choice" do
      node = schema_node({ "oneOf" => [
        { "type" => "object", "description" => "By id", "properties" => { "id" => { "type" => "integer" } } },
        { "type" => "string", "enum" => %w[all none] },
        { "$ref" => "#/components/schemas/Pet" }
      ] }, "Pet" => pet)

      expect(node.type_text).to eq("one of: object, string, Pet")
      expect(node.fields.map(&:name)).to eq([ "option 1", "option 2" ])
      expect(node.fields.first.description).to eq("By id")
      expect(node.fields.first.fields.map(&:name)).to eq(%w[id])
      expect(node.fields.second.enum).to eq(%w[all none])
    end

    it "takes the fields of a single inline option that may be null" do
      node = schema_node({ "oneOf" => [ { "type" => "object", "properties" => { "id" => { "type" => "integer" } } }, { "type" => "null" } ] })

      expect(node.type_text).to eq("object or null")
      expect(node.fields.map(&:name)).to eq(%w[id])
    end

    it "names arrays by their items" do
      node = schema_node({ "type" => "object", "properties" => {
        "a" => { "type" => "array", "items" => { "$ref" => "#/components/schemas/Pet" } },
        "b" => { "type" => "array", "items" => { "type" => "string", "enum" => %w[x y] } },
        "c" => { "type" => "array" },
        "d" => { "type" => [ "array", "null" ], "items" => { "type" => [ "string", "null" ] }, "minItems" => 1 },
        "e" => { "type" => "array", "items" => { "type" => "array", "items" => { "type" => "integer" } } },
        "f" => { "type" => "array", "items" => { "oneOf" => [ { "$ref" => "#/components/schemas/Pet" }, { "type" => "null" } ] } }
      } }, "Pet" => pet)

      expect(node.fields.map(&:type_text)).to eq(
        [ "array of Pet", "array of string", "array", "array of (string or null) or null", "array of array of integer", "array of (Pet or null)" ]
      )
      expect(field(node, "a").fields).to eq([])
      expect(field(node, "b").enum).to eq(%w[x y])
      expect(field(node, "d").notes).to eq([ [ "min items", "1" ] ])
    end

    it "expands inline objects, nested and inside arrays" do
      node = schema_node({ "type" => "object", "properties" => {
        "error" => { "type" => "object", "required" => [ "code" ], "properties" => {
          "code" => { "type" => "string" },
          "detail" => { "type" => [ "object", "null" ], "properties" => { "line" => { "type" => "integer" } } }
        } },
        "rows" => { "type" => "array", "items" => { "type" => "object", "description" => "A row", "properties" => { "n" => { "type" => "integer" } } } }
      } })

      error = field(node, "error")
      expect(error.type_text).to eq("object")
      expect(error.fields.map { |entry| [ entry.name, entry.required ] }).to eq([ [ "code", true ], [ "detail", false ] ])
      expect(field(error, "detail").type_text).to eq("object or null")
      expect(field(error, "detail").fields.map(&:name)).to eq(%w[line])

      rows = field(node, "rows")
      expect(rows.type_text).to eq("array of object")
      expect(rows.description).to eq("A row")
      expect(rows.fields.map(&:name)).to eq(%w[n])
    end

    it "names maps and open objects" do
      node = schema_node({ "type" => "object", "properties" => {
        "a" => { "type" => "object", "additionalProperties" => { "type" => "integer" } },
        "b" => { "type" => "object", "additionalProperties" => { "$ref" => "#/components/schemas/Pet" } },
        "c" => { "type" => "object", "additionalProperties" => false, "properties" => { "x" => { "type" => "string" } } },
        "d" => { "type" => "object", "additionalProperties" => true },
        "e" => { "type" => "object", "additionalProperties" => { "type" => "string" }, "properties" => { "x" => { "type" => "string" } } },
        "f" => { "type" => "object", "additionalProperties" => { "type" => "object", "properties" => { "y" => { "type" => "string" } } } },
        "g" => { "properties" => { "x" => { "type" => "string" } } }
      } }, "Pet" => pet)

      expect(node.fields.map(&:type_text)).to eq(
        [ "map of string to integer", "map of string to Pet", "object", "object", "object", "map of string to object", "object" ]
      )
      expect(field(node, "c").notes).to eq([])
      expect(field(node, "d").notes).to eq([ [ "other fields allowed", nil ] ])
      expect(field(node, "e").fields.map { |entry| [ entry.name, entry.type_text ] }).to eq([ [ "x", "string" ], [ "(any other field)", "string" ] ])
      expect(field(node, "f").fields.map(&:name)).to eq(%w[y])
      expect(field(node, "g").fields.map(&:name)).to eq(%w[x])
    end

    it "lists enum values, const, default, example and limits" do
      node = schema_node({ "type" => "object", "properties" => {
        "state" => { "type" => [ "string", "null" ], "enum" => [ "open", "closed", nil ] },
        "kind" => { "const" => "pet" },
        "n" => { "type" => "integer", "minimum" => 0, "maximum" => 10, "default" => 3, "example" => 7 },
        "s" => { "type" => "string", "minLength" => 1, "maxLength" => 5, "pattern" => "^x", "examples" => [ "xa", "xb" ] },
        "flag" => { "type" => "boolean", "default" => false, "deprecated" => true, "readOnly" => true },
        "mixed" => { "enum" => [ 1, "one", true, { "a" => 1 } ] }
      } })

      expect(field(node, "state").type_text).to eq("string or null")
      expect(field(node, "state").enum).to eq(%w[open closed null])
      expect(field(node, "kind").type_text).to eq("any")
      expect(field(node, "kind").notes).to eq([ [ "always", "pet" ] ])
      expect(field(node, "n").notes).to eq([ [ "min", "0" ], [ "max", "10" ], [ "default", "3" ], [ "example", "7" ] ])
      expect(field(node, "s").notes).to eq([ [ "min length", "1" ], [ "max length", "5" ], [ "pattern", "^x" ], [ "example", "xa" ], [ "example", "xb" ] ])
      expect(field(node, "flag").notes).to eq([ [ "default", "false" ], [ "deprecated", nil ], [ "read only", nil ] ])
      expect(field(node, "mixed").enum).to eq([ "1", "one", "true", '{"a":1}' ])
    end

    it "links a schema that refers to itself, and two that refer to each other" do
      ref = reference("components" => { "schemas" => {
        "Node" => { "type" => "object", "properties" => {
          "parent" => { "oneOf" => [ { "$ref" => "#/components/schemas/Node" }, { "type" => "null" } ] },
          "children" => { "type" => "array", "items" => { "$ref" => "#/components/schemas/Node" } },
          "leaf" => { "$ref" => "#/components/schemas/Leaf" }
        } },
        "Leaf" => { "type" => "object", "properties" => { "owner" => { "$ref" => "#/components/schemas/Node" } } },
        "Alias" => { "$ref" => "#/components/schemas/Node" },
        "Self" => { "$ref" => "#/components/schemas/Self" }
      } })
      node = ref.schemas.find { |entry| entry.name == "Node" }.node

      expect(node.fields.map(&:type_text)).to eq([ "Node or null", "array of Node", "Leaf" ])
      expect(node.fields.flat_map(&:fields)).to eq([])
      expect(ref.schemas.find { |entry| entry.name == "Alias" }.node.type_text).to eq("Node")
      expect(ref.schemas.find { |entry| entry.name == "Self" }.node.type_text).to eq("Self")
    end

    it "resolves a ref into a schema's inside in place, and stops when it turns in a circle" do
      node = schema_node({ "type" => "object", "properties" => {
        "a" => { "$ref" => "#/components/schemas/Pet/properties/name" },
        "b" => { "$ref" => "#/components/schemas/Subject/properties/b" },
        "c" => { "$ref" => "#/components/schemas/Missing" },
        "d" => { "$ref" => "other.yaml#/components/schemas/Far" },
        "e" => { "$ref" => 5 }
      } }, "Pet" => pet)

      expect(node.fields.map(&:type_text)).to eq(%w[string b Missing Far any])
      expect(node.fields.flat_map(&:type).grep(described_class::Link)).to eq([])
    end

    it "ignores keywords and types it does not know" do
      node = schema_node({ "type" => "object", "x-internal" => true, "unevaluatedProperties" => false, "if" => { "x" => 1 },
                           "properties" => { "a" => { "type" => "string", "contentEncoding" => "base64", "xml" => { "name" => "a" } },
                                             "b" => { "type" => "money" }, "c" => true, "d" => { "type" => { "odd" => 1 } },
                                             "e" => { "type" => "string", "enum" => "not a list", "minimum" => { "x" => 1 } } },
                           "required" => "a" })

      expect(node.fields.map { |entry| [ entry.name, entry.type_text, entry.required ] }).to eq(
        [ [ "a", "string", false ], [ "b", "money", false ], [ "c", "any", false ], [ "d", "any", false ], [ "e", "string", false ] ]
      )
      expect(node.notes).to eq([])
      expect(field(node, "e").enum).to be_nil
    end
  end

  describe ".current" do
    it "reads the document of the application" do
      current = described_class.current

      expect(current.title).to eq("Hackorum API")
      expect(current.operations.map(&:anchor)).to include("op-getMe")
      expect(current.schemas.map(&:name)).to include("Topic")
      expect(current.digest).to match(/\A\h{32,}\z/)
      expect(described_class.current).to equal(current)
    end
  end
end
