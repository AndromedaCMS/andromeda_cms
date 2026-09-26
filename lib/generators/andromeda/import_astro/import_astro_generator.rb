# frozen_string_literal: true

require "andromeda_cms"
require "active_support/core_ext/string/inflections"
require_relative "content_config_converter"
require_relative "astro_schema_json"
require_relative "mdx_import_rewriter"
require_relative "mdx_content_scanner"
require_relative "../component/component_generator"

module Andromeda
  module Generators
    # `rails g andromeda:import_astro PATH_TO_ASTRO_PROJECT [--dry-run]`
    # -- one-shot migration of an existing Astro
    # project's content into a host app already set up with
    # `andromeda:install`:
    #
    #   1. Copy every collection's content directory into `app/content/
    #      <collection>/`, and `src/assets` into `app/assets/`, rewriting
    #      only frontmatter keys and MDX
    #      import statements -- otherwise byte-for-byte.
    #   2. Convert `src/content.config.ts` into one `Andromeda::Entry`
    #      subclass per collection, mapping the Zod shapes
    #      Astro supports; anything else becomes a commented-out line with a
    #      TODO rather than a silent omission.
    #   3. Generate a partial stub for every MDX component tag that has no
    #      partial yet.
    #   4. Print a migration report: what was copied/rewritten/generated,
    #      and everything that still needs a human.
    #
    # `--dry-run` runs the exact same analysis and prints the same report,
    # but writes nothing -- implemented as Thor's own `--pretend`, which
    # every `create_file`/`copy_file` call below already respects, rather
    # than a second no-op code path to keep in sync with the real one.
    class ImportAstroGenerator < Rails::Generators::Base
      argument :astro_path, type: :string, banner: "PATH_TO_ASTRO_PROJECT"
      class_option :dry_run, type: :boolean, default: false,
                              desc: "Print the migration report without writing any files"

      def import
        # Thor's own options Hash is frozen by the time a command runs, so
        # `--dry-run` is translated into Thor's built-in `--pretend`
        # (which every `create_file`/`copy_file` call below already
        # respects) via a fresh, unfrozen Hash rather than an in-place
        # mutation.
        self.options = options.merge(pretend: true) if options[:dry_run]

        @report = {
          copied: [], frontmatter_renames: [], import_rewrites: [],
          models: [], stubs: [], unsupported_schema: [], unsupported_expressions: [],
          schema_json_used: [], notes: []
        }

        load_collections
        copy_collections
        copy_assets
        generate_entry_classes
        generate_component_stubs
        print_report
      end

      private

      def astro_root
        @astro_root ||= File.expand_path(astro_path)
      end

      def config_path
        File.join(astro_root, "src/content.config.ts")
      end

      # @return [Array<ImportAstro::ContentConfigConverter::Collection>]
      def load_collections
        @collections =
          if File.file?(config_path)
            ImportAstro::ContentConfigConverter.parse(File.read(config_path), astro_root: astro_root)
          else
            @report[:notes] << "no src/content.config.ts found -- falling back to every directory under " \
                                "src/content/ with no schema"
            fallback_collections
          end

        @collections.each { |collection| refine_with_json_schema!(collection) }
      end

      # The fallback clause: every top-level directory under
      # `src/content/` becomes a schema-less collection so the content
      # itself is still migrated even without a `content.config.ts`.
      def fallback_collections
        base = File.join(astro_root, "src/content")
        return [] unless Dir.exist?(base)

        Dir.children(base).select { |name| File.directory?(File.join(base, name)) }.sort.map do |name|
          ImportAstro::ContentConfigConverter::Collection.new(
            name: name, base: File.join(base, name), pattern: "**/*.{md,mdx}", attributes: []
          )
        end
      end

      # Prefers the generated JSON Schema -- see astro_schema_json.rb
      # for exactly what it can and cannot correct.
      def refine_with_json_schema!(collection)
        schema_json = ImportAstro::AstroSchemaJson.read(astro_root, collection.name)
        return unless schema_json

        @report[:schema_json_used] << collection.name
        collection.attributes.each do |attr|
          required = ImportAstro::AstroSchemaJson.required?(schema_json, attr.name)
          attr.required = required unless required.nil?

          next unless attr.ruby_type == :float

          precision = ImportAstro::AstroSchemaJson.numeric_precision(schema_json, attr.name)
          attr.ruby_type = precision if precision
        end
      end

      def copy_collections
        @collections.each do |collection|
          next unless Dir.exist?(collection.base)

          Dir.glob(File.join(collection.base, "**/*")).sort.each do |src|
            next unless File.file?(src)

            relative = src.delete_prefix("#{collection.base}/")
            dest = "app/content/#{collection.name}/#{relative}"
            copy_content_file(src, dest)
          end
        end
      end

      # Byte-for-byte except for the two rewrites below, and
      # only for `.md`/`.mdx` files -- a sibling image living inside a
      # directory-form entry (`my-post/cover.png`) is copied untouched.
      def copy_content_file(src, dest)
        extension = File.extname(src).downcase
        unless %w[.md .mdx].include?(extension)
          create_file dest, File.binread(src)
          @report[:copied] << dest
          return
        end

        source = File.read(src)
        fixed, renames = Andromeda::Fix.fix_source(source)
        renames.each { |from, to| @report[:frontmatter_renames] << "#{dest}: #{from} -> #{to}" }

        if extension == ".mdx"
          fixed, rewrites = ImportAstro::MdxImportRewriter.rewrite(fixed)
          rewrites.each { |r| @report[:import_rewrites] << "#{dest}: #{r[:from]} -> #{r[:to]}" }
        end

        create_file dest, fixed
        @report[:copied] << dest

        scan_mdx_content(fixed, dest) if extension == ".mdx"
      end

      def scan_mdx_content(source, dest)
        (@component_usages ||= {}).merge!(
          ImportAstro::MdxContentScanner.component_usages(source, path: dest)
        ) { |_name, existing, incoming| existing.props |= incoming.props; existing }

        @report[:unsupported_expressions].concat(
          ImportAstro::MdxContentScanner.unsupported_expressions(source, path: dest)
        )
      end

      def copy_assets
        assets_root = File.join(astro_root, "src/assets")
        return unless Dir.exist?(assets_root)

        Dir.glob(File.join(assets_root, "**/*")).sort.each do |src|
          next unless File.file?(src)

          relative = src.delete_prefix("#{assets_root}/")
          dest = "app/assets/#{relative}"
          create_file dest, File.binread(src)
          @report[:copied] << dest
        end
      end

      def generate_entry_classes
        @collections.each do |collection|
          path = model_path(collection)
          create_file path, model_content(collection)
          @report[:models] << path

          collection.attributes.select(&:unsupported?).each do |attr|
            @report[:unsupported_schema] << "#{collection.name}.#{attr.name} (content.config.ts: #{attr.source})"
          end
        end
      end

      def generate_component_stubs
        return unless @component_usages

        @component_usages.each_value do |usage|
          next if partial_exists?(usage.name)

          # Reuses the real `andromeda:component` generator (rather than
          # duplicating its stub-content logic here) via Thor's own
          # `invoke`, which shares this generator's `destination_root`
          # automatically. `pretend:` is passed through explicitly --
          # `invoke` only inherits a fresh invocation's *original* options
          # (captured at construction time), not this instance's later
          # `self.options = options.merge(pretend: true)` translation of
          # `--dry-run` above.
          invoke Andromeda::Generators::ComponentGenerator, [usage.name, *usage.props], pretend: options[:dry_run]
          @report[:stubs] << component_partial_path(usage.name)
        end
      end

      def partial_exists?(name)
        File.exist?(File.join(destination_root, component_partial_path(name)))
      end

      def component_partial_path(name)
        "#{Andromeda.config.components_path}/_#{Andromeda::Components.underscore(name)}.html.erb"
      end

      def namespace_modules
        @namespace_modules ||= Andromeda.config.entry_namespace.split("::")
      end

      def model_path(collection)
        File.join(Andromeda.config.entry_class_path, "#{collection.name.to_s.singularize}.rb")
      end

      def model_content(collection)
        indent = "  " * namespace_modules.size
        lines = ["# frozen_string_literal: true", ""]
        namespace_modules.each_with_index { |mod, i| lines << "#{"  " * i}module #{mod}" }
        lines << "#{indent}class #{collection.name.to_s.singularize.camelize} < Andromeda::Entry"
        lines << "#{indent}  collection :#{collection.name}, base: \"app/content/#{collection.name}\", " \
                 "pattern: \"#{collection.pattern}\""

        unless collection.attributes.empty?
          lines << ""
          collection.attributes.each { |attr| attribute_lines(attr).each { |line| lines << "#{indent}  #{line}" } }
        end

        lines << "#{indent}end"
        namespace_modules.size.downto(1) { |i| lines << "#{"  " * (i - 1)}end" }
        "#{lines.join("\n")}\n"
      end

      # @return [Array<String>] one or more lines for this attribute: a
      #   real `attribute` declaration, or -- when the Zod expression could
      #   not be mapped -- a `# TODO` naming the original source plus a
      #   commented-out best guess, never a silent omission.
      def attribute_lines(attr)
        return unsupported_attribute_lines(attr) if attr.unsupported?

        lines = []
        lines << "# NOTE: #{attr.note}" if attr.note
        lines << "attribute :#{snake_name(attr)}, :#{attr.ruby_type}#{attribute_modifiers(attr)}"
        lines
      end

      def unsupported_attribute_lines(attr)
        [
          "# TODO: unsupported schema for `#{attr.name}` in content.config.ts (#{attr.source}) -- " \
          "add the equivalent `attribute` by hand.",
          "# attribute :#{snake_name(attr)}, :string"
        ]
      end

      # The generated class's `attribute` calls must use the same
      # snake_case names `Andromeda::Fix` gives the frontmatter keys
      # themselves -- `pubDate` in `content.config.ts` has to line
      # up with `pub_date:` in the copied Markdown, or the schema would
      # look for a key that no longer exists in the file.
      def snake_name(attr)
        Andromeda::Fix.snake_case(attr.name)
      end

      def attribute_modifiers(attr)
        parts = []
        parts << "of: :#{attr.of}" if attr.ruby_type == :array && attr.of
        parts << "values: #{attr.values.inspect}" if attr.ruby_type == :enum
        parts << "collection: :#{attr.collection}" if attr.ruby_type == :reference
        parts << "required: true" if attr.required && attr.default.nil?
        parts << "default: #{attr.default}" if attr.default
        parts.empty? ? "" : ", #{parts.join(", ")}"
      end

      def print_report
        say ""
        say(options[:dry_run] ? "Astro import (dry run -- nothing was written):" : "Astro import complete:")
        say ""
        report_section "Copied", @report[:copied]
        report_section "Frontmatter keys renamed to snake_case", @report[:frontmatter_renames]
        report_section "MDX import statements rewritten", @report[:import_rewrites]
        report_section "Entry classes generated", @report[:models]
        report_section "Component stubs generated", @report[:stubs]
        report_section "Collections that used Astro's generated JSON Schema", @report[:schema_json_used]
        say ""
        say "Needs a human:"
        report_section "  Unmapped schema fields", @report[:unsupported_schema], indent: "    "
        report_section "  Expressions the renderer cannot evaluate", @report[:unsupported_expressions], indent: "    "
        report_section "  Notes", @report[:notes], indent: "    "
      end

      def report_section(title, items, indent: "  ")
        return if items.empty?

        say "#{title}:"
        items.each { |item| say "#{indent}#{item}" }
        say ""
      end
    end
  end
end
