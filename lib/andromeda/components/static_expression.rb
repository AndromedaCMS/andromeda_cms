# frozen_string_literal: true

require_relative "../renderer/literal_expression"

module Andromeda
  class Components
    # The v0 "static expression" evaluator: the only
    # `{...}` expressions Andromeda ever evaluates are bare literals, a
    # `frontmatter.x` (or `frontmatter.a.b`) property chain, and MDX
    # comments. Everything else raises `UnsupportedExpressionError` rather
    # than silently degrading -- unlike
    # `Andromeda::Renderer::LiteralExpression`, which exists specifically to
    # give the *renderer* something to fall back to when it has no
    # frontmatter/error-reporting context of its own: `.map()`, ternaries,
    # `await`, arrow functions, and template interpolation are all
    # unsupported and deliberately out of scope for both.
    module StaticExpression
      UnsupportedExpressionError = Class.new(StandardError)

      FRONTMATTER_PATH_RE = /\Afrontmatter(\.[A-Za-z_$][\w$]*)+\z/.freeze

      module_function

      # @param source [String] raw text between `{` and `}`.
      # @param frontmatter [Hash] the entry's validated frontmatter data
      #   (symbol or string keyed; `Andromeda::Schema#validate!` produces
      #   symbol keys -- see lib/andromeda/schema.rb -- but string keys are
      #   accepted too so this doesn't care which the caller has on hand).
      # @return [Object] the evaluated value.
      # @raise [UnsupportedExpressionError] if `source` is not a literal, a
      #   `frontmatter.x` reference, or a comment.
      def evaluate(source, frontmatter: {})
        trimmed = source.to_s.strip
        return "" if comment?(trimmed)

        literal, matched = try_literal(source)
        return literal if matched

        return dig_frontmatter(frontmatter, trimmed.split(".")[1..]) if FRONTMATTER_PATH_RE.match?(trimmed)

        raise UnsupportedExpressionError, source
      end

      def comment?(trimmed)
        trimmed.start_with?("/*") && trimmed.end_with?("*/")
      end

      # Runs the same recursive-descent grammar `LiteralExpression` uses,
      # but -- unlike `LiteralExpression.evaluate` -- reports whether the
      # whole source was consumed as a literal instead of silently handing
      # back the original string on failure; that distinction is exactly
      # what tells this module whether to move on to the frontmatter/error
      # path instead of treating a non-literal string as if it evaluated to
      # itself.
      def try_literal(source)
        parser = Andromeda::Renderer::LiteralExpression::Parser.new(source)
        value = parser.parse_value
        parser.skip_ws
        parser.eof? ? [value, true] : [nil, false]
      rescue Andromeda::Renderer::LiteralExpression::Parser::Error
        [nil, false]
      end

      # @param frontmatter [Hash]
      # @param segments [Array<String>] property names after `frontmatter.`.
      # @return [Object, nil] `nil` for a missing key, mirroring JS
      #   `undefined` property access rather than raising -- `{frontmatter.x}`
      #   for an optional field that is absent should render as empty, not
      #   blow up the whole page.
      def dig_frontmatter(frontmatter, segments)
        segments.reduce(frontmatter) do |value, segment|
          break nil if value.nil? || !value.is_a?(Hash)

          value.key?(segment.to_sym) ? value[segment.to_sym] : value[segment]
        end
      end
    end
  end
end
