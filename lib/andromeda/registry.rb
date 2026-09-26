# frozen_string_literal: true

module Andromeda
  # Maps collection name (`:blog`) to the `Andromeda::Entry` subclass that
  # declared it (`Content::Post`), so `Andromeda.get_collection`/`get_entry`
  # and cross-collection `reference` resolution can find a class by name
  # alone.
  #
  # ## How collection classes get found in development
  #
  # In production, Rails eager loads `app/models/`, so every `Content::*`
  # class runs its `collection` macro (and thus registers itself) simply by
  # being loaded -- no discovery step needed. In development, autoloading is
  # lazy: a class that nothing has referenced yet (the exact situation for
  # an STI-style class only ever looked up by a symbol, never a Ruby
  # constant) never runs, so `Registry[:blog]` would come back empty even
  # though `app/models/content/post.rb` exists on disk.
  #
  # `discover` closes that gap by force-loading every `.rb` file under a
  # directory (default `app/models/content`, the conventional content
  # class location), which runs each file's `collection` call and populates
  # this registry as a side effect. It uses `Kernel#load` rather than
  # `require`, because `require` is a no-op the second time it sees the same
  # absolute path -- exactly the case on every code reload after the first
  # boot, and load is required for `discover` to be reload-safe.
  #
  # This module is intentionally Rails-agnostic: it doesn't reference
  # `Rails`, `ActiveSupport::Reloader`, or zeitwerk. The Railtie is
  # expected to call `discover` from a `Rails.application.reloader.to_prepare`
  # block, which already runs once at boot and again after every reload in
  # development -- giving `discover` the "run again after files changed"
  # trigger for free without this file needing to know reloading exists.
  # One caveat left unresolved: `to_prepare` fires after Rails'
  # own autoloader (Zeitwerk) has already unloaded stale constants for
  # *changed* files, but a class we reach via a plain `load` (bypassing
  # Zeitwerk's own autoload hook) is not necessarily one Zeitwerk considers
  # itself responsible for unloading. If that turns out to matter in
  # practice, the Railtie can instead trigger the load by referencing
  # the constant Zeitwerk expects (`Rails.autoloaders.main.eager_load_dir`)
  # rather than calling `Kernel#load` directly -- `discover` below is the
  # dependency-free fallback for that decision, not the final word on it.
  #
  # `clear!` before rebuilding is what makes a second `discover` call safe:
  # without it, a renamed or deleted entry class would linger in the
  # registry as a zombie pointing at a stale class object whose constant no
  # longer resolves to it.
  module Registry
    DEFAULT_DIRECTORY = "app/models/content"

    class << self
      # @param name [Symbol, String]
      # @param entry_class [Class] an Andromeda::Entry subclass.
      def register(name, entry_class)
        entries[name.to_sym] = entry_class
      end

      # @return [Class, nil]
      def [](name)
        entries[name.to_sym]
      end

      # @return [Array<Symbol>]
      def collection_names
        entries.keys
      end

      # Wipes every registration. Called automatically at the start of
      # `discover`; exposed on its own for tests that need a clean slate.
      def clear!
        @entries = {}
      end

      # Force-loads every `.rb` file under `dir`, registering whatever
      # `collection` calls they contain. See the module comment for why
      # this clears the registry first and uses `load` rather than
      # `require`.
      #
      # @param dir [String] absolute path to a directory of entry classes.
      def discover(dir = default_directory)
        clear!
        Dir.glob(File.join(dir, "**", "*.rb")).sort.each { |file| load file }
        self
      end

      # @return [String] `app/models/content` under Rails.root when Rails is
      #   loaded, or under the current working directory otherwise (kept
      #   Rails-agnostic so plain-Ruby usage and tests don't need Rails).
      def default_directory
        File.join(Andromeda.config.project_root, DEFAULT_DIRECTORY)
      end

      private

      def entries
        @entries ||= {}
      end
    end
  end

  class << self
    # Astro's `getCollection("blog")`, returning every entry.
    #
    # @param name [Symbol, String]
    # @return [Andromeda::Relation]
    # @raise [Andromeda::UnknownCollection]
    def get_collection(name)
      entry_class_for(name).all
    end

    # Astro's `getEntry("blog", id)`.
    #
    # @param name [Symbol, String]
    # @param id [String]
    # @return [Andromeda::Entry]
    # @raise [Andromeda::UnknownCollection]
    # @raise [Andromeda::EntryNotFound]
    def get_entry(name, id)
      entry_class_for(name).find(id)
    end

    private

    def entry_class_for(name)
      Registry[name] || raise(Andromeda::UnknownCollection, name.to_sym)
    end
  end
end
