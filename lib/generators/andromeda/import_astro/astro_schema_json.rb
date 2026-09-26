# frozen_string_literal: true

require "json"

module Andromeda
  module Generators
    module ImportAstro
      # Astro writes a resolved JSON Schema per collection to
      # `.astro/collections/<name>.schema.json` whenever it has run at least
      # once (`astro sync`/`astro dev`/`astro build`). This
      # generator prefers that file over parsing `content.config.ts` by
      # hand when it is available.
      #
      # In practice the two sources are complementary rather than one
      # strictly superseding the other:
      #
      # - The JSON Schema is Astro's own fully-resolved output -- it reflects
      #   whatever Zod actually decided about `required`/type after unions,
      #   refinements, etc., which a regex over the TypeScript source can
      #   only approximate. It is therefore the more trustworthy source for
      #   **required-ness** and for telling `z.number()` (JSON Schema
      #   `"number"`) apart from a `.int()`-refined one (`"integer"`).
      # - It cannot tell `image()`/`reference(...)` apart from a plain
      #   string, has no notion of a `.default()` *value*, and (being JSON)
      #   cannot express a Ruby-side type name at all. Those still need
      #   `ContentConfigConverter`'s read of the TypeScript.
      #
      # So `ImportAstroGenerator` always parses `content.config.ts` (it is
      # the only source for the Astro-specific helpers and defaults), and
      # additionally reads this file, when present, to correct
      # required-ness and refine `z.number()` into `:integer`/`:float`. See
      # `ImportAstroGenerator#refine_with_json_schema!`.
      module AstroSchemaJson
        module_function

        # @param astro_root [String]
        # @param collection_name [String]
        # @return [Hash, nil] the parsed `properties`/`required` shape, or
        #   nil if Astro never generated one for this collection.
        def read(astro_root, collection_name)
          path = File.join(astro_root, ".astro/collections/#{collection_name}.schema.json")
          return nil unless File.file?(path)

          JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        end

        # @param schema_json [Hash] as returned by `read`.
        # @param field_name [String]
        # @return [Boolean, nil] nil when the field is not described at all
        #   (the generator then leaves the TS-derived required-ness alone).
        def required?(schema_json, field_name)
          return nil unless schema_json.is_a?(Hash)

          properties = schema_json["properties"]
          return nil unless properties.is_a?(Hash) && properties.key?(field_name)

          Array(schema_json["required"]).include?(field_name)
        end

        # @return [Symbol, nil] `:integer` or `:float` when the field is a
        #   JSON Schema number/integer, nil otherwise (including when the
        #   field is absent) so the generator only ever narrows a `:float`
        #   guess, never overrides an unrelated type.
        def numeric_precision(schema_json, field_name)
          return nil unless schema_json.is_a?(Hash)

          property = (schema_json["properties"] || {})[field_name]
          return nil unless property.is_a?(Hash)

          case property["type"]
          when "integer" then :integer
          when "number" then :float
          end
        end
      end
    end
  end
end
