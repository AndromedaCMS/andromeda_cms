# frozen_string_literal: true

module Andromeda
  # Rewrites frontmatter keys that are not snake_case, the one migration
  # step content copied from an Astro project reliably needs.
  #
  # The rewrite is textual on purpose: round-tripping through a YAML/TOML
  # emitter would reformat quoting, key order and comments, turning a
  # two-key rename into an unreviewable diff.
  module Fix
    KEY_LINE = /\A(\s*)(["']?)([A-Za-z_][A-Za-z0-9_-]*)\2(\s*[:=]\s*)/

    module_function

    # @param entry_classes [Array<Class>] defaults to every registered collection.
    # @param write [Boolean] false previews the changes without touching disk.
    # @return [Array<String>] one line per renamed key, ready to print.
    def run(entry_classes = Andromeda::Pipeline.default_entry_classes, write: true)
      changes = []

      content_files(entry_classes).each do |path|
        source = File.read(path)
        fixed, renames = fix_source(source)
        next if renames.empty?

        File.write(path, fixed) if write
        renames.each { |from, to| changes << "#{path}: #{from} -> #{to}" }
      end

      changes
    end

    # @return [Array(String, Array<Array(String, String)>)] the rewritten
    #   source and the renames applied to it.
    def fix_source(source)
      frontmatter, _format, = Andromeda::Frontmatter.split(source)
      return [source, []] if frontmatter.nil?

      renames = []
      fixed_frontmatter = frontmatter.lines.map do |line|
        match = KEY_LINE.match(line)
        # Only top-level keys are renamed: an indented key belongs to a
        # nested structure whose shape the schema does not describe.
        next line unless match && match[1].empty?

        key = match[3]
        snake = snake_case(key)
        next line if snake == key

        renames << [key, snake]
        line.sub(KEY_LINE) { "#{match[1]}#{match[2]}#{snake}#{match[2]}#{match[4]}" }
      end.join

      [source.sub(frontmatter, fixed_frontmatter), renames]
    end

    def snake_case(key)
      key
        .gsub("-", "_")
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .downcase
    end

    def content_files(entry_classes)
      entry_classes.flat_map do |entry_class|
        Dir.glob(File.join(entry_class.base_dir, entry_class.pattern)).sort
      end
    end
  end
end
