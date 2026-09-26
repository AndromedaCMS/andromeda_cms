# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# The dummy application boots first so the whole suite loads the gem the way
# an application does -- Rails first, then andromeda_cms, so the Railtie is
# picked up. Requiring the gem on its own here would leave every later test
# running against a Rails-less load order no real app ever has.
require_relative "dummy/config/environment"
require "andromeda_cms"
require "minitest/autorun"

module ParserAssertions
  # Recursively strips `:position` so structural assertions don't have to
  # hardcode line/column/offset for every node; position itself has its own
  # dedicated tests.
  def strip_positions(node)
    case node
    when Hash
      node.each_with_object({}) do |(k, v), out|
        next if k == :position

        out[k] = strip_positions(v)
      end
    when Array
      node.map { |n| strip_positions(n) }
    else
      node
    end
  end

  # mdxJsxAttribute/mdxJsxExpressionAttribute/mdxJsxAttributeValueExpression
  # are attribute *records*, not mdast nodes in their own right (they never
  # appear in a `children` array) — unist's Position contract only applies to
  # actual tree nodes, so these intentionally carry no `:position`.
  NON_POSITIONED_TYPES = %w[
    mdxJsxAttribute
    mdxJsxExpressionAttribute
    mdxJsxAttributeValueExpression
  ].freeze

  # Asserts every mdast node reachable via `:children` (recursively) has a
  # well-formed unist Position: 1-based line/column, non-negative offset,
  # end >= start. Only walks `:children` (not every Hash value) so
  # non-node fields like `attributes`/`align` aren't mistaken for nodes.
  def assert_all_positions_present(node)
    case node
    when Hash
      if node.key?(:type) && !NON_POSITIONED_TYPES.include?(node[:type])
        assert node.key?(:position), "node #{node[:type].inspect} is missing :position"
        pos = node[:position]
        %i[start end].each do |side|
          point = pos[side]
          assert_kind_of Integer, point[:line]
          assert_kind_of Integer, point[:column]
          assert_kind_of Integer, point[:offset]
          assert_operator point[:line], :>=, 1
          assert_operator point[:column], :>=, 1
        end
        assert_operator pos[:end][:offset], :>=, pos[:start][:offset]
      end
      assert_all_positions_present(node[:children]) if node[:children]
    when Array
      node.each { |n| assert_all_positions_present(n) }
    end
  end
end

module Minitest
  class Test
    include ParserAssertions
  end
end
