# frozen_string_literal: true

module Andromeda
  class Renderer
    # Minimal evaluator for MDX/JSX attribute *expressions* that are plain
    # literals: numbers, booleans, `null`, strings, arrays, and objects --
    # covering prop values that are themselves literals. This is
    # deliberately not a JS expression evaluator -- no identifiers, member
    # access, calls, operators, or template literals. Those are handled
    # elsewhere (`{frontmatter.x}`, `.map()`, etc.); here, anything that is not
    # a bare literal is left as the original source text so callers can
    # still render *something* (e.g. `Counter count={1 + 1}` becomes the
    # attribute value `"1 + 1"`, not a raised error) while a fuller
    # evaluator can upgrade this later.
    module LiteralExpression
      module_function

      # @param source [String] the raw text between `{` and `}` in
      #   `mdxJsxAttributeValueExpression`/`mdxFlowExpression`/etc (i.e. what
      #   `nodes.rs` already stripped the braces from).
      # @return [Object] the evaluated Ruby value (String/Integer/Float/
      #   true/false/nil/Array/Hash) if `source` is a bare literal;
      #   otherwise `source` itself, unchanged.
      def evaluate(source)
        parser = Parser.new(source)
        value = parser.parse_value
        parser.skip_ws
        parser.eof? ? value : source
      rescue Parser::Error
        source
      end

      # Hand-rolled recursive-descent parser over a small literal grammar.
      # Not built on Ruby's JSON parser because object keys here are often
      # unquoted JS identifiers (`{a: 1}`), which is invalid JSON.
      class Parser
        Error = Class.new(StandardError)

        IDENTIFIER_START = /[A-Za-z_$]/
        IDENTIFIER_CHAR = /[A-Za-z0-9_$]/
        NUMBER = /\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/

        def initialize(source)
          @s = source
          @i = 0
        end

        def eof?
          @i >= @s.length
        end

        def skip_ws
          @i += 1 while !eof? && @s[@i].match?(/\s/)
        end

        def parse_value
          skip_ws
          raise Error, "unexpected end of expression" if eof?

          case @s[@i]
          when "{" then parse_object
          when "[" then parse_array
          when '"', "'" then parse_string
          else
            parse_keyword || parse_number || (raise Error, "unexpected #{@s[@i].inspect} at #{@i}")
          end
        end

        def parse_keyword
          %w[true false null undefined].each do |word|
            next unless @s[@i, word.length] == word
            # Guard against matching a prefix of a longer identifier, e.g.
            # `truest` should not parse as `true` followed by garbage.
            after = @s[@i + word.length]
            next if after && after.match?(IDENTIFIER_CHAR)

            @i += word.length
            return { "true" => true, "false" => false, "null" => nil, "undefined" => nil }[word]
          end
          nil
        end

        def parse_number
          match = NUMBER.match(@s[@i..])
          return nil unless match

          @i += match[0].length
          text = match[0]
          text.include?(".") || text.include?("e") || text.include?("E") ? text.to_f : text.to_i
        end

        def parse_string
          quote = @s[@i]
          @i += 1
          buf = +""
          while true
            raise Error, "unterminated string" if eof?

            char = @s[@i]
            if char == quote
              @i += 1
              return buf
            elsif char == "\\"
              @i += 1
              raise Error, "unterminated string" if eof?

              buf << unescape(@s[@i])
              @i += 1
            else
              buf << char
              @i += 1
            end
          end
        end

        def unescape(char)
          { "n" => "\n", "t" => "\t", "r" => "\r", "b" => "\b", "f" => "\f" }.fetch(char, char)
        end

        def parse_array
          @i += 1 # consume '['
          values = []
          skip_ws
          if peek == "]"
            @i += 1
            return values
          end
          loop do
            values << parse_value
            skip_ws
            case peek
            when ","
              @i += 1
              skip_ws
              # Trailing comma before ']'.
              if peek == "]"
                @i += 1
                return values
              end
            when "]"
              @i += 1
              return values
            else
              raise Error, "expected ',' or ']' at #{@i}"
            end
          end
        end

        def parse_object
          @i += 1 # consume '{'
          object = {}
          skip_ws
          if peek == "}"
            @i += 1
            return object
          end
          loop do
            skip_ws
            key = parse_object_key
            skip_ws
            raise Error, "expected ':' at #{@i}" unless peek == ":"

            @i += 1
            object[key] = parse_value
            skip_ws
            case peek
            when ","
              @i += 1
              skip_ws
              if peek == "}"
                @i += 1
                return object
              end
            when "}"
              @i += 1
              return object
            else
              raise Error, "expected ',' or '}' at #{@i}"
            end
          end
        end

        def parse_object_key
          case peek
          when '"', "'" then parse_string
          else
            raise Error, "expected object key at #{@i}" unless peek&.match?(IDENTIFIER_START)

            start = @i
            @i += 1 while !eof? && @s[@i].match?(IDENTIFIER_CHAR)
            @s[start...@i]
          end
        end

        def peek
          eof? ? nil : @s[@i]
        end
      end
    end
  end
end
