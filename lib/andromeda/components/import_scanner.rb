# frozen_string_literal: true

module Andromeda
  class Components
    # Reads `mdxjsEsm` nodes out of an mdast tree and extracts a
    # `name -> import path` map, so `Andromeda::Components` can resolve a
    # component tag by the path it was imported from (second in the
    # precedence order: explicit registration > import path >
    # naming convention).
    #
    # This is deliberately not a JS parser: MDX import statements are a tiny,
    # regular subset of ES module syntax (default imports and named imports,
    # optionally `as`-renamed), and Sätteri has already validated the source
    # is syntactically valid MDX by the time an `mdxjsEsm` node exists at
    # all. A handful of regexes over that node's raw text is enough to cover
    # every import shape Astro's compiler recognizes, without carrying a JS
    # grammar around for it.
    module ImportScanner
      # `import Foo from '...'` / `import Foo from "..."`.
      DEFAULT_IMPORT_RE = /import\s+([A-Za-z_$][\w$]*)\s+from\s+(['"])(.*?)\2/.freeze

      # `import { A, B as C } from '...'`.
      NAMED_IMPORT_RE = /import\s*\{([^}]*)\}\s*from\s+(['"])(.*?)\2/.freeze

      NAMED_BINDING_RE = /\A([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?\z/.freeze

      module_function

      # @param tree [Hash] an mdast root node.
      # @return [Hash{String => String}] the name a component tag would use
      #   in the document, mapped to the raw import path/specifier. An
      #   `import cover from './cover.png'` ends up here too, which is how
      #   Components resolves `{cover}` passed as a prop to an image.
      def scan(tree)
        imports = {}

        each_esm_source(tree) do |source|
          source.scan(DEFAULT_IMPORT_RE) { |name, _quote, path| imports[name] = path }

          source.scan(NAMED_IMPORT_RE) do |bindings, _quote, path|
            bindings.split(",").each do |binding|
              binding = binding.strip
              next if binding.empty?

              match = NAMED_BINDING_RE.match(binding)
              next unless match

              local_name = match[2] || match[1]
              imports[local_name] = path
            end
          end
        end

        imports
      end

      # Walks the whole tree (not just `root.children`) so this keeps
      # working even if a future Sätteri version nests `mdxjsEsm` nodes
      # somewhere other than the top level; valid MDX only ever has them at
      # the top level today, so in practice this is a single pass over a
      # short list.
      def each_esm_source(node, &block)
        return unless node.is_a?(Hash)

        yield node[:value].to_s if node[:type] == "mdxjsEsm"
        (node[:children] || []).each { |child| each_esm_source(child, &block) }
      end
      private_class_method :each_esm_source
    end
  end
end
