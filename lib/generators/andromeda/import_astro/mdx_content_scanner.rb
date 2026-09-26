# frozen_string_literal: true

require_relative "../../../andromeda/components/static_expression"

module Andromeda
  module Generators
    module ImportAstro
      # Parses an already-copied `.mdx` file with the real Sätteri-backed
      # `Andromeda::Parser` (rather than a second regex pass) to find:
      #
      # - every JSX component tag actually used, with the prop names seen on
      #   it (for generating partial stubs), and
      # - every `{...}` expression that `Andromeda::Components::
      #   StaticExpression` -- the same evaluator the real renderer uses --
      #   cannot evaluate, for the migration report's "expressions the
      #   renderer cannot evaluate" section.
      #
      # This only inspects the tree; it never renders anything, so it needs
      # no view layer and works the same whether or not the host app has
      # partials yet.
      module MdxContentScanner
        ComponentUsage = Struct.new(:name, :props, keyword_init: true)

        module_function

        # @param source [String] MDX source, already import-rewritten (the
        #   rewrite does not change tag usage, so scan order does not
        #   matter).
        # @param path [String] for error messages only.
        # @return [Hash{String => ComponentUsage}] tag name -> usage,
        #   `Fragment` excluded (never a real component).
        def component_usages(source, path:)
          tree = Andromeda::Parser.parse(source, mdx: true, path: path)
          usages = {}

          walk(tree) do |node|
            next unless %w[mdxJsxFlowElement mdxJsxTextElement].include?(node[:type])

            name = node[:name]
            next if name.nil? || name == "Fragment" || name.include?(".")

            usage = (usages[name] ||= ComponentUsage.new(name: name, props: []))
            (node[:attributes] || []).each do |attribute|
              next unless attribute[:type] == "mdxJsxAttribute"

              usage.props << attribute[:name] unless usage.props.include?(attribute[:name])
            end
          end

          usages
        rescue Andromeda::SyntaxError, Andromeda::ParserError
          # Not this generator's job to diagnose a broken source file --
          # `andromeda:check`/the renderer will raise the same error again,
          # with the same message, once the file is actually rendered. The
          # migration report calls this out instead of failing the import.
          {}
        end

        # @return [Array<String>] one line per expression the renderer would
        #   raise on, `"path:line: {source}"`.
        def unsupported_expressions(source, path:)
          tree = Andromeda::Parser.parse(source, mdx: true, path: path)
          problems = []

          walk(tree) do |node|
            next unless %w[mdxFlowExpression mdxTextExpression].include?(node[:type])

            begin
              Andromeda::Components::StaticExpression.evaluate(node[:value].to_s, frontmatter: {})
            rescue Andromeda::Components::StaticExpression::UnsupportedExpressionError
              line = node.dig(:position, :start, :line)
              problems << "#{path}:#{line}: {#{node[:value]}}"
            end
          end

          problems
        rescue Andromeda::SyntaxError, Andromeda::ParserError
          []
        end

        def walk(node, &block)
          return unless node.is_a?(Hash)

          yield node if node[:type]
          (node[:children] || []).each { |child| walk(child, &block) }
        end
        private_class_method :walk
      end
    end
  end
end
