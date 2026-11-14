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
        # `notes` are things about the collection itself (not one field)
        # that still need a human -- e.g. a `pattern` this importer cannot
        # carry over as written. Defaults to empty so existing
        # `Collection.new` calls stay valid.
        Collection = Struct.new(:name, :base, :pattern, :attributes, :notes, keyword_init: true) do
          def initialize(notes: [], **rest) = super(notes: notes, **rest)
        end

        DEFAULT_PATTERN = "**/*.{md,mdx}"

        COLLECTION_RE = /const\s+(\w+)\s*=\s*defineCollection\s*\(/.freeze

        # Bash-style extglob openers (`!(drafts)`, `@(a|b)`, ...), which
        # Astro's glob loader accepts but Ruby's `Dir.glob` does not.
        EXTGLOB_RE = /[!@+*?]\(/.freeze

        # One frontmatter field. `ruby_type` is nil when the Zod expression
        # could not be recognized at all -- `source` (the original
        # expression text) is always kept so the generator can turn it into
        # a TODO comment naming exactly what needs a human (per the
        # generator's "never a silent omission" requirement).
        #
        # `default` is an already-parsed Ruby value (never source text), and
        # `has_default` says whether there is one at all -- `default: false`
        # and "no default" must not collapse into the same nil.
        Attribute = Struct.new(
          :name, :ruby_type, :required, :default, :has_default, :of, :values, :collection, :source, :note,
          keyword_init: true
        ) do
          def unsupported? = ruby_type.nil?
          def default? = has_default ? true : false
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

        # Returned by `parse_literal` for anything it does not recognize, so
        # that a literal `nil`/`false` default stays distinguishable.
        UNPARSEABLE = Object.new.freeze

        # The JS string escapes `parse_js_string` decodes. Any other
        # backslash sequence makes the whole literal unparseable rather
        # than risk decoding it differently from JS.
        JS_STRING_ESCAPES = {
          "\\" => "\\", "'" => "'", '"' => '"', "/" => "/", "$" => "$",
          "n" => "\n", "t" => "\t", "r" => "\r", "b" => "\b", "f" => "\f", "v" => "\v"
        }.freeze

        # `\xHH`, `\uHHHH` and `\u{H...}`; `\0` only when no digit follows
        # (`\01` is a legacy octal escape, which is not decoded).
        JS_CODE_ESCAPE_RE = /\G(?:x(\h{2})|u(\h{4})|u\{(\h{1,6})\}|0(?!\d))/.freeze

        # The field names the generator can declare: after
        # `Andromeda::Fix.snake_case` these become plain Ruby symbols.
        FIELD_NAME_RE = /\A[A-Za-z_][A-Za-z0-9_-]*\z/.freeze

        module_function

        # @param source [String] the full `content.config.ts` contents.
        # @param astro_root [String] absolute path to the Astro project, used
        #   to resolve a `loader: glob({ base: ... })` path.
        # @return [Array<Collection>]
        def parse(source, astro_root:)
          # Each match's own position is used: looking the name up again
          # with `index("const #{name}")` would find `const blog` inside
          # `const blogPosts`, and rescanning from the top for every
          # collection made a large file quadratic.
          source.to_enum(:scan, COLLECTION_RE).filter_map do
            match = Regexp.last_match
            paren = match.end(0) - 1
            close = BalancedScanner.matching_close(source, paren)
            next unless close

            build_collection(match[1], source[(paren + 1)...close], astro_root: astro_root)
          end
        end

        def build_collection(name, body, astro_root:)
          body = BalancedScanner.strip_comments(body)
          base = extract_string(body, /base\s*:/) || "./src/content/#{name}"
          pattern, notes = extract_pattern(body)

          # The pattern ends up in the generated class and is globbed from
          # `app/content/<name>/` at runtime, so one that climbs out of it
          # (`../../config/*`, `/etc/*`, `~/...`) is not carried over.
          if escapes_base?(pattern)
            notes << "pattern `#{pattern}` reaches outside the collection directory -- " \
                     "replaced with `#{DEFAULT_PATTERN}`"
            pattern = DEFAULT_PATTERN
          end

          Collection.new(
            name: name,
            base: File.expand_path(base, astro_root),
            pattern: pattern,
            attributes: extract_attributes(body),
            notes: notes
          )
        end

        # Astro's `glob({ pattern: ... })` also takes an array (with `!`
        # exclusions) and extglob syntax -- neither of which `Dir.glob`
        # understands. Rather than silently dropping them, the closest
        # usable pattern is kept and a note says what was lost.
        #
        # @return [Array(String, Array<String>)] the pattern and any notes.
        def extract_pattern(body)
          match = /pattern\s*:\s*\[/.match(body)
          return extract_array_pattern(body, match.end(0) - 1) if match

          pattern = extract_string(body, /pattern\s*:/) || DEFAULT_PATTERN
          return [pattern, []] unless pattern.match?(EXTGLOB_RE)

          [pattern, ["pattern `#{pattern}` uses extglob syntax, which Ruby's glob does not support -- " \
                     "no files will match this pattern"]]
        end

        # Only what was actually lost gets a note: `!` exclusions (still
        # copied and loaded) and any further non-exclusion patterns (copied
        # but not loaded). A one-element or empty array loses nothing.
        def extract_array_pattern(body, open_index)
          close = BalancedScanner.matching_close(body, open_index)
          # Squished onto one line: the note also becomes a `# TODO` comment.
          source = body[open_index..close].gsub(/\s+/, " ")
          elements = BalancedScanner.split_top_level(body[(open_index + 1)...close]).map do |literal|
            literal.gsub(/\A(['"`])(.*)\1\z/, '\2')
          end.reject(&:empty?)
          exclusions, includes = elements.partition { |element| element.start_with?("!") }
          pattern = includes.first || DEFAULT_PATTERN
          dropped = includes.drop(1)

          notes = []
          unless exclusions.empty?
            notes << "exclusions #{backticked(exclusions)} from pattern array #{source} are not applied, " \
                     "so the files they exclude are still copied and loaded"
          end
          unless dropped.empty?
            notes << "patterns #{backticked(dropped)} from pattern array #{source} were dropped " \
                     "(only `#{pattern}` was kept), so files matching only them are copied but not loaded"
          end
          [pattern, notes]
        end

        def escapes_base?(pattern)
          pattern.start_with?("/", "~") || pattern.split(%r{[/\\]}).include?("..")
        end

        def backticked(elements)
          elements.map { |element| "`#{element}`" }.join(", ")
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
          # A quoted key can hold anything (`"a; system('…')": ...`); only a
          # name that is a plain identifier is declared, anything else goes
          # to the TODO list.
          unless key.match?(FIELD_NAME_RE)
            return Attribute.new(
              name: key, ruby_type: nil, required: false, source: expr,
              note: "field name `#{key}` is not a valid attribute name"
            )
          end

          expr, required, default, has_default, dropped_default = strip_modifiers(expr)
          type, extra = classify(expr)

          notes = [extra[:note]]
          if dropped_default
            notes << "default `#{dropped_default}` is not a plain literal and was not carried over -- " \
                     "set `default:` by hand"
          end

          Attribute.new(
            name: key, ruby_type: type, required: type.nil? ? false : required,
            default: default, has_default: has_default,
            of: extra[:of], values: extra[:values], collection: extra[:collection],
            source: expr, note: notes.compact.join("; ").then { |note| note.empty? ? nil : note }
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
          has_default = false
          dropped_default = nil

          loop do
            if expr.end_with?(".optional()")
              expr = expr[0...-".optional()".length].strip
              required = false
            elsif (inner = unwrap_call(expr, "z.optional"))
              expr = inner.strip
              required = false
            elsif (inner = suffix_call_argument(expr, ".default"))
              has_default, default = literal_default(inner)
              dropped_default = has_default ? nil : inner.strip
              expr = expr[0...-(".default(#{inner})".length)].strip
              required = false
            else
              break
            end
          end

          [expr, required, default, has_default, dropped_default]
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

        # Parses a `.default(...)` argument into a Ruby value: `true`/`false`,
        # an integer, a float, a quoted string, or an array of those.
        # Anything else is dropped. The text itself is never carried over --
        # the generator writes the value back out with `inspect`, so a JS
        # string like `"#{system('…')}"` can never become Ruby code.
        #
        # @return [Array(Boolean, Object)] whether a default was recognized,
        #   and its value.
        def literal_default(text)
          value = parse_literal(text.strip, allow_array: true)
          value.equal?(UNPARSEABLE) ? [false, nil] : [true, value]
        end

        def parse_literal(text, allow_array:)
          case text
          when "true" then true
          when "false" then false
          # A leading zero is left out: JS reads `0123` as legacy octal (83).
          when /\A-?(?:0|[1-9]\d*)\z/ then Integer(text, 10)
          when /\A-?(?:0|[1-9]\d*)\.\d+\z/
            # A literal too large for a Float becomes `Infinity`, which
            # `inspect` writes as an undefined constant.
            value = Float(text)
            value.finite? ? value : UNPARSEABLE
          when /\A(['"]).*\1\z/m then parse_js_string(text)
          when /\A\[.*\]\z/m
            return UNPARSEABLE unless allow_array

            values = BalancedScanner.split_top_level(text[1...-1]).map do |element|
              parse_literal(element, allow_array: false)
            end
            values.any? { |value| value.equal?(UNPARSEABLE) } ? UNPARSEABLE : values
          else
            UNPARSEABLE
          end
        end

        # Decodes a single- or double-quoted JS string literal (including
        # its quotes). Returns UNPARSEABLE for an unescaped closing quote or
        # newline inside it, or an escape outside JS_STRING_ESCAPES.
        def parse_js_string(text)
          quote = text[0]
          body = text[1...-1]
          result = +""
          i = 0

          while i < body.length
            char = body[i]
            if char == "\\"
              if (decoded = JS_STRING_ESCAPES[body[i + 1]])
                result << decoded
                i += 2
              elsif (code = JS_CODE_ESCAPE_RE.match(body, i + 1))
                codepoint = (code[1] || code[2] || code[3] || "0").to_i(16)
                # A lone surrogate half (`\uD83D`) has no UTF-8 encoding.
                return UNPARSEABLE if codepoint > 0x10FFFF || (0xD800..0xDFFF).cover?(codepoint)

                result << codepoint.chr(Encoding::UTF_8)
                i = code.end(0)
              else
                return UNPARSEABLE
              end
            elsif char == quote || char == "\n"
              return UNPARSEABLE
            else
              result << char
              i += 1
            end
          end

          result
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
