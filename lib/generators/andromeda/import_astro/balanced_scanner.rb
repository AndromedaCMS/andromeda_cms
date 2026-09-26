# frozen_string_literal: true

module Andromeda
  module Generators
    module ImportAstro
      # Small bracket-matching helpers shared by ContentConfigConverter and
      # MdxImportRewriter. `content.config.ts` is TypeScript, but the shapes
      # this generator needs to recognize (Astro's collection-config shapes)
      # are a tiny, regular subset of it -- matching parens/braces/brackets
      # while skipping over string literals is enough to find where a call
      # or object literal ends, without carrying an actual TS parser around
      # (the same reasoning `Andromeda::Components::ImportScanner` already
      # applies to MDX import statements).
      module BalancedScanner
        OPEN_TO_CLOSE = { "(" => ")", "{" => "}", "[" => "]" }.freeze
        QUOTES = ["'", '"', "`"].freeze

        module_function

        # @param source [String]
        # @param open_index [Integer] index of an opening bracket in `source`.
        # @return [Integer, nil] the index of its matching closing bracket, or
        #   nil if `source` ends before one is found (malformed/truncated
        #   input -- callers treat that the same as "not found").
        def matching_close(source, open_index)
          open_char = source[open_index]
          close_char = OPEN_TO_CLOSE.fetch(open_char)
          depth = 0
          i = open_index

          while i < source.length
            char = source[i]

            if QUOTES.include?(char)
              i = skip_string(source, i)
              next
            elsif char == open_char
              depth += 1
            elsif char == close_char
              depth -= 1
              return i if depth.zero?
            end

            i += 1
          end

          nil
        end

        # @return [Integer] the index just past the closing quote.
        def skip_string(source, quote_index)
          quote = source[quote_index]
          i = quote_index + 1
          while i < source.length
            case source[i]
            when "\\" then i += 1 # escaped char, skip it too
            when quote then return i + 1
            end
            i += 1
          end
          i
        end

        # Splits `source` (the inside of a `{...}` or `(...)`, braces
        # excluded) on top-level commas -- i.e. commas that are not nested
        # inside their own brackets or a string literal. Used both for
        # `z.object({ ... })` fields and for `z.enum([...])`/`z.array(...)`
        # argument lists.
        #
        # @return [Array<String>] trimmed, non-empty segments (a trailing
        #   comma produces no empty segment).
        def split_top_level(source)
          segments = []
          depth = 0
          current = +""
          i = 0

          while i < source.length
            char = source[i]

            if QUOTES.include?(char)
              stop = skip_string(source, i)
              current << source[i...stop]
              i = stop
              next
            elsif OPEN_TO_CLOSE.key?(char)
              depth += 1
            elsif OPEN_TO_CLOSE.value?(char)
              depth -= 1
            end

            if char == "," && depth.zero?
              segments << current
              current = +""
            else
              current << char
            end

            i += 1
          end
          segments << current unless current.strip.empty?

          segments.map(&:strip).reject(&:empty?)
        end

        # Strips `//line` and `/* block */` comments from `source`,
        # preserving everything inside string literals untouched. Astro's
        # own examples comment their schema fields (`// Transform string to
        # Date object`) -- without this, such a comment would fuse onto the
        # start of the next field's key when `split_top_level`/
        # `split_key_value` see it as ordinary text.
        def strip_comments(source)
          result = +""
          i = 0

          while i < source.length
            char = source[i]

            if QUOTES.include?(char)
              stop = skip_string(source, i)
              result << source[i...stop]
              i = stop
            elsif source[i, 2] == "//"
              i = (source.index("\n", i) || source.length)
            elsif source[i, 2] == "/*"
              close = source.index("*/", i + 2)
              i = close ? close + 2 : source.length
            else
              result << char
              i += 1
            end
          end

          result
        end

        # Splits `field: expression` on the first top-level colon -- the key
        # is always a bare identifier or a quoted string, never containing
        # brackets, so the first depth-0 colon is unambiguous.
        #
        # @return [Array(String, String), nil] `[key, expression]`, or nil if
        #   no top-level colon is found at all.
        def split_key_value(source)
          depth = 0
          i = 0
          while i < source.length
            char = source[i]

            if QUOTES.include?(char)
              i = skip_string(source, i)
              next
            elsif OPEN_TO_CLOSE.key?(char)
              depth += 1
            elsif OPEN_TO_CLOSE.value?(char)
              depth -= 1
            elsif char == ":" && depth.zero?
              key = source[0...i].strip.gsub(/\A(['"])(.*)\1\z/, '\2')
              return [key, source[(i + 1)..].strip]
            end

            i += 1
          end
          nil
        end
      end
    end
  end
end
