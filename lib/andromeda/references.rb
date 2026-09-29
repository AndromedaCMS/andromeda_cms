# frozen_string_literal: true

require "set"

module Andromeda
  # Checks that every `:reference` attribute -- on its own or as the
  # elements of an `:array` -- names an entry that actually exists.
  #
  # Entries resolve references lazily (Entry#resolve_reference), so without
  # this a typo in an id only surfaces when a page asks for the target. It
  # needs every target collection loaded, which is why only the whole-site
  # build (Pipeline.build_all) and Andromeda::Check run it.
  module References
    module_function

    # @param entries_by_class [Hash{Class => Array<Andromeda::Entry>}]
    #   entries already loaded, reused as reference targets. A target
    #   collection missing from here is loaded from source.
    # @return [Array<String>] human-readable problems; empty when every
    #   reference resolves.
    def problems(entries_by_class)
      ids = Hash.new { |cache, name| cache[name] = ids_for(name, entries_by_class) }

      entries_by_class.flat_map do |entry_class, entries|
        attributes = reference_attributes(entry_class)
        next [] if attributes.empty?

        entries.flat_map do |entry|
          attributes.flat_map do |attr|
            references_in(entry.data[attr.name]).filter_map do |reference|
              problem_for(reference, ids[reference.collection])&.then do |message|
                "[#{entry_class.collection_name}] #{entry.file_path}: #{attr.name}: #{message}"
              end
            end
          end
        end
      end
    end

    def reference_attributes(entry_class)
      entry_class.schema.attributes.values.select do |attr|
        attr.type == :reference || (attr.type == :array && attr.of == :reference)
      end
    end

    # `Array(value)` would splat a single Reference (a Struct) into its
    # fields, so the two shapes are told apart explicitly.
    def references_in(value)
      (value.is_a?(Array) ? value : [value]).grep(Andromeda::Reference)
    end

    def problem_for(reference, known)
      return "unknown collection #{reference.collection.inspect}" if known == :unknown
      # The target collection failed to load; that failure is reported on
      # its own, and every reference into it would only repeat it.
      return nil if known.nil?
      return nil if known.include?(reference.id.to_s)

      "no #{reference.collection.inspect} entry with id #{reference.id.to_s.inspect}"
    end

    def ids_for(name, entries_by_class)
      entry_class = Andromeda::Registry[name]
      return :unknown if entry_class.nil?

      entries = entries_by_class.fetch(entry_class) { entry_class.source_entries }
      entries.map(&:id).to_set
    rescue Andromeda::LoaderError
      nil
    end
  end
end
