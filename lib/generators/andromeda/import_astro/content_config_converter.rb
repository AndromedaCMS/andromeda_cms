# frozen_string_literal: true

require_relative "balanced_scanner"

module Andromeda
  module Generators
    module ImportAstro
      # Turns an Astro `src/content.config.ts` into the data
      # `ImportAstroGenerator` needs to write one `Andromeda::Entry` subclass
      # per collection.
      #
      # This is a static-analysis converter, not a TypeScript parser: Astro's
      # own collection config is always one of a handful of call shapes
      # (`defineCollection({ loader: glob({...}), schema: z.object({...}) })`,
      # optionally with `schema: ({ image }) => z.object({...})`), so a
      # regex + bracket-matching pass over the source text is enough to find
      # them, the same trade-off `Andromeda::Components::ImportScanner`
      # already makes for MDX import statements. Anything shaped differently
      # falls through to `Attribute#unsupported?` rather than guessing.
      module ContentConfigConverter
        Collection = Struct.new(:name, :base, :pattern, :attributes, keyword_init: true)

        # One frontmatter field. `ruby_type` is nil when the Zod expression
        # could not be recognized at all -- `source` (the original
        # expression text) is always kept so the generator can turn it into
        # a TODO comment naming exactly what needs a human (per the
        # generator's "never a silent omission" requirement).
        Attribute = Struct.new(
          :name, :ruby_type, :required, :default, :of, :values, :collection, :source, :note,
          keyword_init: true
        ) do
          def unsupported? = ruby_type.nil?
        end

        # Astro's own base Zod types. Order matters: more specific
        # patterns (`z.coerce.date()`) must be tried before the more general
        # ones they could otherwise collide with in a naive match.
        SCALAR_PATTERNS = [
          [/\Az\.string\(\)\z/, :string],
          [/\Az\.number\(\)\z/, :float],
          [/\Az\.boolean\(\)\z/, :boolean],
          [/\Az\.coerce\.date\(\)\z/, :date],
          [/\Az\.date\(\)\z/, :date]
        ].freeze

        DEFAULT_LITERAL_RE = /\A(?:true|false|-?\d+(?:\.\d+)?|'[^']*'|"[^"]*"|\[[^\]]*\])\z/.freeze

        module_function

        # @param source [String] the full `content.config.ts` contents.
        # @param astro_root [String] absolute path to the Astro project, used
        #   to resolve a `loader: glob({ base: ... })` path.
        # @return [Array<Collection>]
        def parse(source, astro_root:)
          source.scan(/const\s+(\w+)\s*=\s*defineCollection\s*\(/).flatten.map do |const_name|
            open = source.index("defineCollection", source.index("const #{const_name}"))
            paren = source.index("(", open)
            close = BalancedScanner.matching_close(source, paren)
            body = source[(paren + 1)...close]

            build_collection(const_name, body, astro_root: astro_root)
          end
        end

        def build_collection(name, body, astro_root:)
          body = BalancedScanner.strip_comments(body)
          base = extract_string(body, /base\s*:/) || "./src/content/#{name}"
          pattern = extract_string(body, /pattern\s*:/) || "**/*.{md,mdx}"

          Collection.new(
            name: name,
            base: File.expand_path(base, astro_root),
            pattern: pattern,
            attributes: extract_attributes(body)
          )
        end

        # @return [String, nil] the quoted value right after `label_re`, e.g.
        #   `base: './src/content/blog'` -> `"./src/content/blog"`.
        def extract_string(body, label_re)
          match = /#{label_re}\s*(['"])(.*?)\1/.match(body)
          match && match[2]
        end

        def extract_attributes(body)
          object_open = find_schema_object(body)
          return [] unless object_open

          close = BalancedScanner.matching_close(body, object_open)
          fields_source = body[(object_open + 1)...close]

          BalancedScanner.split_top_level(fields_source).filter_map do |field|
            key, expr = BalancedScanner.split_key_value(field)
            next if key.nil?

            build_attribute(key, expr)
          end
        end

        # Finds the `{` of `z.object({ ... })`, whether the schema is given
        # directly (`schema: z.object({...})`) or behind the `({ image }) =>`
        # helper form Astro's own examples use for `image()` fields.
        def find_schema_object(body)
          match = /schema\s*:.*?z\.object\s*\(\s*\{/m.match(body)
          return nil unless match

          match.end(0) - 1
        end

        def build_attribute(key, expr)
          expr, required, default = strip_modifiers(expr)
          type, extra = classify(expr)

          Attribute.new(
            name: key, ruby_type: type, required: type.nil? ? false : required, default: default,
            of: extra[:of], values: extra[:values], collection: extra[:collection],
            source: expr, note: extra[:note]
          )
        end

        # Repeatedly peels `.optional()`/`z.optional(...)`/`.default(...)`
        # wrappers off the outside of `expr` until none remain, tracking
        # whether the field ended up optional and what its default literal
        # is (Astro/Zod semantics: `.optional()` and `.default()` both make
        # a field non-required; only `.default()` also supplies a value).
        def strip_modifiers(expr)
          required = true
          default = nil

          loop do
            if expr.end_with?(".optional()")
              expr = expr[0...-".optional()".length].strip
              required = false
            elsif (inner = unwrap_call(expr, "z.optional"))
              expr = inner.strip
              required = false
            elsif (inner = suffix_call_argument(expr, ".default"))
              default = literal_default(inner)
              expr = expr[0...-(".default(#{inner})".length)].strip
              required = false
            else
              break
            end
          end

          [expr, required, default]
        end

        # @return [String, nil] the argument text of a trailing `.method(...)`
        #   call, if `expr` ends with exactly that call.
        def suffix_call_argument(expr, method_name)
          marker = "#{method_name}("
          index = expr.rindex(marker)
          return nil unless index

          close = BalancedScanner.matching_close(expr, index + method_name.length)
          return nil unless close == expr.length - 1

          expr[(index + marker.length)...close]
        end

        # @return [String, nil] the argument text of `prefix(...)` when
        #   `expr` is exactly that call (not just contains it).
        def unwrap_call(expr, prefix)
          marker = "#{prefix}("
          return nil unless expr.start_with?(marker)

          close = BalancedScanner.matching_close(expr, prefix.length)
          return nil unless close == expr.length - 1

          expr[(prefix.length + 1)...close]
        end

        # Only a recognizable Ruby-literal-compatible default is carried
        # over verbatim (JS and Ruby agree on `true`/`false`/numbers/quoted
        # strings/arrays-of-those); anything else is dropped and the field
        # falls back to being flagged unsupported by `classify` seeing an
        # expression it was not built to trust the shape of.
        def literal_default(text)
          text.strip.match?(DEFAULT_LITERAL_RE) ? text.strip : nil
        end

        # @return [Array(Symbol, Hash), Array(nil, Hash)] the Ruby attribute
        #   type (nil if unrecognized) and any type-specific extras
        #   (`of:`/`values:`/`collection:`/`note:`).
        def classify(expr)
          SCALAR_PATTERNS.each do |pattern, type|
            return [type, {}] if pattern.match?(expr)
          end

          if (inner = unwrap_call(expr, "z.enum"))
            return classify_enum(inner)
          end

          if (inner = unwrap_call(expr, "z.array"))
            return classify_array(inner)
          end

          return [:image, {}] if expr == "image()"

          if (match = /\Areference\(\s*(['"])(.*?)\1\s*\)\z/.match(expr))
            return [:reference, { collection: match[2].to_sym }]
          end

          [nil, {}]
        end

        def classify_enum(inner)
          bracket_match = /\A\[(.*)\]\z/m.match(inner.strip)
          return [nil, {}] unless bracket_match

          values = BalancedScanner.split_top_level(bracket_match[1]).map do |literal|
            literal.strip.gsub(/\A(['"])(.*)\1\z/, '\2')
          end
          [:enum, { values: values }]
        end

        # `of:` only carries over for a scalar element type Andromeda's own
        # Schema supports for arrays (03-6) -- an array of something more
        # exotic (`z.array(z.object({...}))`) is left with `of: nil` and a
        # note, so the generator's TODO explains exactly why rather than
        # silently guessing.
        def classify_array(inner)
          element_type, = classify(inner.strip)
          return [:array, { of: element_type }] if element_type

          [:array, { of: nil, note: "array element type `#{inner.strip}` is not a supported scalar" }]
        end
      end
    end
  end
end
