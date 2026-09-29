# frozen_string_literal: true

module Andromeda
  # The read-only counterpart of `andromeda:build`, for CI.
  #
  # It deliberately runs the *same* conversion the build runs, into a
  # throwaway store, rather than re-implementing a subset of the checks: a
  # check that passes while the build fails would be worse than no check at
  # all. Everything it finds is reported together, because fixing content
  # one error per CI run is miserable.
  module Check
    module_function

    # @param entry_classes [Array<Class>] defaults to every registered collection.
    # @return [Array<String>] human-readable problems; empty when content is healthy.
    def run(entry_classes = Andromeda::Pipeline.default_entry_classes)
      problems = []
      loaded = {}

      entry_classes.each do |entry_class|
        entries = load_entries(entry_class, problems)
        next if entries.nil?

        loaded[entry_class] = entries
        entries.each do |entry|
          problems.concat(frontmatter_style_problems(entry))
          problems.concat(conversion_problems(entry))
        end
      end

      problems.concat(Andromeda::References.problems(loaded))
    end

    def load_entries(entry_class, problems)
      entry_class.reload!
      entry_class.all.to_a
    rescue Andromeda::LoaderError => e
      problems.concat(e.messages.map { |message| "[#{entry_class.collection_name}] #{message}" })
      nil
    rescue Andromeda::Error => e
      problems << "[#{entry_class.collection_name}] #{e.message}"
      nil
    end

    # Non-snake_case keys are legal YAML but will not reach a declared
    # attribute, so they are reported here with the command that rewrites
    # them instead of failing later as a missing required field.
    def frontmatter_style_problems(entry)
      offenders = Andromeda::Frontmatter.non_snake_case_keys(entry.data)
      return [] if offenders.empty?

      offenders.map do |key|
        "#{entry.file_path}: frontmatter key #{key} is not snake_case; run `bin/rails andromeda:fix`"
      end
    end

    def conversion_problems(entry)
      Andromeda::Pipeline.new(store: NullStore.new, mode: :development).convert(entry)
      []
    rescue Andromeda::Error => e
      ["#{entry.file_path}: #{e.message}"]
    end

    # Swallows the writes so a check can never leave `.andromeda/` in a
    # half-built state that a later production boot would happily serve.
    class NullStore
      def write_entry(*) = nil
      def read_entry(*) = nil
      def read_index(*) = nil
      def replace_collection!(*) = nil
    end
  end
end
