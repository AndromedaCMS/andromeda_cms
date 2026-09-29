# frozen_string_literal: true

require "pathname"

module Andromeda
  # The base class users subclass to define a collection:
  #
  #   class Content::Post < Andromeda::Entry
  #     collection :blog, base: "app/content/blog", pattern: "**/*.{md,mdx}"
  #
  #     attribute :title,    :string, required: true
  #     attribute :pub_date, :date,   required: true
  #     attribute :draft,    :boolean, default: false
  #
  #     scope :published, -> { where(draft: false) }
  #   end
  #
  #   Content::Post.published.order(pub_date: :desc).limit(10)
  #   Content::Post.find("hello-world")   # => Content::Post
  #   Content::Post.find("nope")          # => raises Andromeda::EntryNotFound
  #
  # `Entry` only holds source-derived data (`id`/`collection`/`data`/`body`/
  # `file_path`/`digest`) -- it does not render HTML. Rendering is the
  # renderer's job and the store's; this class exists so
  # they have something to render/persist in the first place.
  class Entry
    class << self
      # @return [Symbol, nil] set by `collection`.
      attr_reader :collection_name
      # @return [String, nil] absolute path, set by `collection`.
      attr_reader :base_dir
      # @return [String, nil] a Dir.glob pattern relative to `base_dir`.
      attr_reader :pattern

      # Declares this class as the entry type for `name`, registering it in
      # Andromeda::Registry so `Andromeda.get_collection`/`get_entry`
      # and `reference` resolution can find it by name.
      #
      # @param name [Symbol, String]
      # @param base [String] absolute, or relative to Rails.root (or the
      #   current working directory outside Rails).
      # @param pattern [String] a Dir.glob pattern, relative to `base`.
      def collection(name, base:, pattern: "**/*.{md,mdx}")
        @collection_name = name.to_sym
        @base_dir = resolve_base(base)
        @pattern = pattern
        @entries = nil
        Andromeda::Registry.register(@collection_name, self)
        self
      end

      # Declares one frontmatter attribute, delegating all type/validation
      # logic to Andromeda::Schema (this class never reimplements it) and
      # additionally defining an instance reader so `post.title` works as
      # a shorthand for `post.data[:title]`.
      #
      # A `:reference` attribute gets a different reader: it resolves the
      # stored `Andromeda::Reference` to the actual target entry (lazily,
      # via the registry) rather than returning the pointer itself --
      # `post.data[:author]` still holds the raw Reference for callers that
      # want it. An `:array` of `:reference` resolves each element the same
      # way, so `post.tags` returns the tag entries.
      #
      # @see Andromeda::Schema#attribute for the full parameter list.
      def attribute(name, type, **options)
        schema.attribute(name, type, **options)
        attr_name = name.to_sym

        if type == :reference
          define_method(attr_name) { resolve_reference(attr_name) }
        elsif type == :array && options[:of] == :reference
          define_method(attr_name) { resolve_references(attr_name) }
        else
          define_method(attr_name) { data[attr_name] }
        end

        self
      end

      # `scope :published, -> { where(draft: false) }`. The block runs via
      # `instance_exec` against an Andromeda::Relation (either `all`, at the
      # class level, or an existing Relation when chained), so it can call
      # `where`/`order`/other scopes unqualified.
      #
      # @param name [Symbol]
      # @param callable [Proc]
      def scope(name, callable)
        name = name.to_sym
        scopes[name] = callable
        define_singleton_method(name) { |*args| all.public_send(name, *args) }
        self
      end

      # @return [Hash{Symbol => Proc}] public so Andromeda::Relation can look
      #   up a scope by name when one is chained off a Relation instance.
      def scopes
        @scopes ||= {}
      end

      # @return [Andromeda::Schema] this class's own, never inherited/shared
      #   -- each subclass declares its own attributes independently.
      def schema
        @schema ||= Andromeda::Schema.new
      end

      # @return [Andromeda::Relation] every loaded entry.
      def all
        Andromeda::Relation.new(entries, entry_class: self)
      end

      # @param id [String, Symbol]
      # @return [Andromeda::Entry]
      # @raise [Andromeda::EntryNotFound]
      def find(id)
        target = id.to_s
        entries.find { |entry| entry.id == target } ||
          raise(Andromeda::EntryNotFound.new(collection: collection_name, id: target, candidates: entries.map(&:id)))
      end

      def find_by(conditions = nil, &block)
        all.find_by(conditions, &block)
      end

      def where(conditions = nil, &block)
        all.where(conditions, &block)
      end

      def order(*criteria)
        all.order(*criteria)
      end

      def limit(count)
        all.limit(count)
      end

      def first(count = nil)
        all.first(count)
      end

      def count
        entries.size
      end

      # The list-view counterpart to `all`: in production
      # this reads only `.andromeda/<collection>/_index.json` (no source
      # file, no parsing), the same data an index page needs (`id`/`data`/
      # `headings`/`digest`/`file_path`) without opening every entry's own
      # JSON. In development it refreshes stale entries first so
      # edits show up without a separate build step. Additive: `all`/
      # `find`/`where`/etc. are unchanged and still read source files
      # directly through Andromeda::Loader.
      #
      # @return [Array<Hash>]
      # @raise [Andromeda::BuildMissing] in production, if nothing has been
      #   built for this collection yet.
      def index
        Andromeda::Pipeline.new.collection_index(self)
      end

      # Every entry read and validated from its source file, whatever the
      # mode. This is what `andromeda:build` converts: in production `all`
      # reads the built index instead, which does not exist before the first
      # build and carries no body after it, so a build that went through `all`
      # would either fail or overwrite every page with empty HTML.
      #
      # @return [Array<Andromeda::Entry>]
      # @raise [Andromeda::LoaderError] listing every file that failed.
      def source_entries
        load_entries_from_source
      end

      # Drops the in-memory cache, forcing the next query to re-run the
      # Loader. Used by tests that change fixtures mid-example, and is the
      # hook the dev-mode "reconvert on stale mtime" check will call.
      def reload!
        @entries = nil
      end

      private

      # Production never touches source files: everything a query
      # needs was validated and written to `_index.json` at build time, so
      # reading it back is both faster and immune to a content file that
      # changed on disk after the build. Development goes to the Loader so
      # edits are visible without a build step.
      def entries
        @entries ||= production? ? entries_from_index : load_entries_from_source
      end

      def production?
        Andromeda.config.mode == :production
      end

      def load_entries_from_source
        Andromeda::Loader.new(
          entry_class: self, base: base_dir, pattern: pattern, schema: schema
        ).load
      end

      # The index carries no body: rendering already happened at build time,
      # and `Entry#html` reads the per-entry JSON rather than the body, so a
      # listing never pays for content it does not show.
      def entries_from_index
        index.map do |summary|
          summary = summary.transform_keys(&:to_sym)
          new(
            id: summary[:id],
            collection: collection_name,
            data: summary[:data],
            body: nil,
            file_path: summary[:file_path],
            digest: summary[:digest]
          )
        end
      end

      # `base:` is written as a project-relative string in every example
      # (`"app/content/blog"`) so it reads the same in an initializer-free
      # Rails app either way; resolving it here (rather than deferring to
      # the Loader) keeps the Loader itself Rails-agnostic and testable with
      # plain absolute paths.
      def resolve_base(base)
        return base if Pathname.new(base).absolute?

        File.join(Andromeda.config.project_root, base)
      end
    end

    # @return [String]
    attr_reader :id
    # @return [Symbol]
    attr_reader :collection
    # @return [Hash] Symbol-keyed validated frontmatter (may also carry
    #   String keys for unrecognized frontmatter -- see Schema::Result).
    attr_reader :data
    # @return [String] absolute path to the source file.
    attr_reader :file_path
    # @return [String] SHA-256 of the whole source file, for cache keys.
    attr_reader :digest

    def initialize(id:, collection:, data:, body:, file_path:, digest:)
      @id = id
      @collection = collection
      @data = data
      @body = body
      @file_path = file_path
      @digest = digest
    end

    # The rendered HTML for `body` (MDX components expanded),
    # produced and cached by Andromeda::Pipeline rather than here --
    # this method only decides *when* to ask for it. Memoized on the
    # instance (not globally): a fresh Entry is what a reload/re-Loader-pass
    # produces, carrying today's `digest`, so per-instance memoization can
    # never serve a stale render across a reload the way a class-level or
    # process-wide cache could (see Configuration#mode's dev-mode note).
    #
    # @return [String]
    # @raise [Andromeda::BuildMissing] in production, if this entry has
    #   never been built.
    def html
      converted[:html]
    end

    # The raw Markdown/MDX body, frontmatter stripped but with original line
    # numbers preserved (Andromeda::Frontmatter#parse). Entries loaded from
    # source carry it already; in production they come from the index, which
    # leaves bodies out, so it is read from the entry's built file the same
    # way `html` is.
    #
    # @return [String, nil] nil only for a build made before bodies were
    #   stored (andromeda_cms < 0.1.2); rebuilding fixes it.
    # @raise [Andromeda::BuildMissing] in production, if this entry has
    #   never been built.
    def body
      @body || converted[:body]
    end

    # @return [Array<Hash>] `{depth:, slug:, text:}` per heading, in
    #   document order (Andromeda::Renderer::Result#headings).
    # @raise [Andromeda::BuildMissing] in production, if this entry has
    #   never been built.
    def headings
      converted[:headings]
    end

    # @return [Hash] everything needed to rebuild this entry with `from_h`,
    #   so the build step can persist it (`.andromeda/<collection>/<id>.json`) and
    #   restore it later without re-parsing/re-validating the source file.
    def to_h
      { id: id, collection: collection, data: data, body: body, file_path: file_path, digest: digest }
    end

    # @param hash [Hash] as produced by `to_h` (String or Symbol keys).
    # @return [Andromeda::Entry]
    def self.from_h(hash)
      new(**hash.transform_keys(&:to_sym))
    end

    private

    def converted
      @converted ||= Andromeda::Pipeline.new.fetch(self)
    end

    # @param attr_name [Symbol] a `:reference`-typed attribute.
    # @return [Andromeda::Entry, nil]
    # @raise [Andromeda::EntryNotFound] naming both the target collection
    #   and id, via Entry.find on the referenced collection.
    def resolve_reference(attr_name)
      reference = data[attr_name]
      return nil if reference.nil?

      # Only reached when the caller actually asks for `post.author` --
      # deliberately not resolved (or even looked up) at load time, so
      # referencing an entry never forces every other collection to load.
      Andromeda.get_entry(reference.collection, reference.id)
    end

    # @param attr_name [Symbol] an `:array` attribute declared `of: :reference`.
    # @return [Array<Andromeda::Entry>] in the order the frontmatter lists them.
    # @raise [Andromeda::EntryNotFound] for the first id with no entry.
    def resolve_references(attr_name)
      Array(data[attr_name]).map { |reference| Andromeda.get_entry(reference.collection, reference.id) }
    end
  end
end
