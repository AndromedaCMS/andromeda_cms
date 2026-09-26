# frozen_string_literal: true

module Andromeda
  module Generators
    module ImportAstro
      # Rewrites MDX import statements to the partial-path form:
      # `import Callout from '../../components/Callout.astro';`
      # becomes `import Callout from 'content_components/callout';`. Only
      # component imports are rewritten -- an image import
      # (`import cover from './cover.png'`) is left alone, since `cover` is
      # bound to an asset, not resolved as a JSX tag (image imports are a
      # separate, deferred concern from this rewrite).
      #
      # A regex pass over the raw text, matching
      # `Andromeda::Components::ImportScanner`'s own reasoning: MDX imports
      # are a small, regular subset of ES module syntax, and rewriting only
      # ever needs to look at one import statement at a time.
      module MdxImportRewriter
        DEFAULT_IMPORT_RE = /^import\s+([A-Za-z_$][\w$]*)\s+from\s+(['"])(.*?)\2\s*;?[ \t]*$/
        NAMED_IMPORT_RE = /^import\s*\{([^}]*)\}\s*from\s+(['"])(.*?)\2\s*;?[ \t]*$/
        NAMED_BINDING_RE = /\A([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?\z/
        IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .svg .webp .avif].freeze

        module_function

        # @param source [String] a whole `.mdx` file's contents.
        # @return [Array(String, Array<Hash>)] the rewritten source and a
        #   list of `{from:, to:}` rewrites applied, for the migration
        #   report.
        def rewrite(source)
          rewrites = []

          rewritten = source.gsub(NAMED_IMPORT_RE) do |whole|
            rewrite_named(whole, Regexp.last_match(1), Regexp.last_match(3), rewrites)
          end

          rewritten = rewritten.gsub(DEFAULT_IMPORT_RE) do |whole|
            rewrite_default(whole, Regexp.last_match(1), Regexp.last_match(3), rewrites)
          end

          [rewritten, rewrites]
        end

        def rewrite_default(whole, name, path, rewrites)
          return whole unless component_name?(name) && !image_path?(path)

          replacement = "import #{name} from '#{partial_path(name)}';"
          rewrites << { from: whole.strip, to: replacement }
          replacement
        end

        # A named import list is rewritten only when every binding looks
        # like a component (capitalized) -- one import path cannot honestly
        # become several different partial paths, and a mixed list
        # (components alongside a lowercase helper) is rare enough in
        # practice that leaving it untouched (and letting naming-convention
        # resolution handle the components at render time) is safer than
        # guessing which names to split out.
        def rewrite_named(whole, bindings_source, _path, rewrites)
          bindings = bindings_source.split(",").filter_map { |b| b.strip unless b.strip.empty? }
          locals = bindings.map { |binding| NAMED_BINDING_RE.match(binding) }
          return whole if locals.any?(&:nil?)

          local_names = locals.map { |m| m[2] || m[1] }
          return whole unless local_names.all? { |name| component_name?(name) }

          replacement = local_names.map { |name| "import #{name} from '#{partial_path(name)}';" }.join("\n")
          rewrites << { from: whole.strip, to: replacement }
          replacement
        end

        def component_name?(name)
          name.match?(/\A[A-Z]/)
        end

        def image_path?(path)
          IMAGE_EXTENSIONS.include?(File.extname(path).downcase)
        end

        # @return [String] `content_components/<underscored name>`, matching
        #   the naming-convention `Andromeda::Components` already resolves
        #   tags with, minus the `app/views/` prefix a partial
        #   path never includes.
        def partial_path(name)
          base = Andromeda.config.components_path.sub(%r{\Aapp/views/}, "")
          "#{base}/#{Andromeda::Components.underscore(name)}"
        end
      end
    end
  end
end
