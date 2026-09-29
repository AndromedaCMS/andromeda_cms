# frozen_string_literal: true

require "digest"
require_relative "store"

module Andromeda
  # The one place source -> stored-result conversion happens.
  # Both the development request path (convert this one
  # entry, on demand, if it looks stale) and `andromeda:build` (
  # convert every entry, unconditionally) call `Pipeline#convert`/
  # `#build_collection` -- neither reimplements "frontmatter -> tree -> HTML"
  # on its own, so the two can never drift apart: both always run the same
  # conversion process.
  #
  # A Pipeline instance is cheap and stateless beyond its Store/mode, so
  # callers are free to build a fresh one per request/task rather than
  # reaching for a shared singleton.
  class Pipeline
    # @return [Symbol] result of `Pipeline.build_all`/`#build_collection` for
    #   one collection: how many entries converted cleanly, and every
    #   problem found among the rest (schema violations, missing
    #   components, syntax errors) -- collected rather than raised
    #   individually, so a build reports everything in one pass (same
    #   principle as Andromeda::LoaderError).
    #
    # `entries` holds what was read from source (nil when the collection
    # failed to load), so `.build_all` can check references across
    # collections without reading every file a second time.
    BuildResult = Struct.new(:collection, :converted, :errors, :entries, keyword_init: true) do
      def success? = errors.empty?
    end

    # @param store [Andromeda::Store]
    # @param mode [Symbol, String] `:development` or `:production`.
    #   Defaults to `Andromeda.config.mode`, which itself defaults to
    #   `:development` -- see Configuration's comment for why that default
    #   (rather than `:production`) is the safe one outside a Railtie that
    #   has not set it explicitly yet.
    def initialize(store: Andromeda::Store.new, mode: Andromeda.config.mode)
      @store = store
      @mode = mode.to_sym
    end

    # Converts one already-loaded entry's body into HTML, writes the result
    # to the store, and returns it. Unconditional -- always re-parses and
    # re-renders, even if a stored copy with a matching digest already
    # exists -- because `andromeda:build` needs exactly that ("always
    # produce today's output") and because staleness-checking is `#fetch`'s
    # job, not this one's, so this method has exactly one behaviour to
    # reason about.
    #
    # @param entry [Andromeda::Entry] built by Andromeda::Loader (so
    #   `data`/`body`/`digest`/`file_path` all come straight from the
    #   source file, not from a previous build).
    # @return [Hash] the stored payload (Symbol-keyed: `id`, `collection`,
    #   `data`, `html`, `headings`, `body`, `digest`, `file_path`).
    # @raise [Andromeda::SyntaxError, Andromeda::ParserError,
    #   Andromeda::Renderer::MissingComponentError] on a bad file; callers
    #   that want every problem across a whole collection reported together
    #   should go through `#build_collection` instead of calling this
    #   directly in a loop.
    def convert(entry)
      mdx = Andromeda::Parser.mdx?(entry.file_path)
      tree = Andromeda::Parser.parse(entry.body, mdx: mdx, path: entry.file_path)
      result = Andromeda::Renderer.new(
        components: components_for(entry, tree),
        image_resolver: image_resolver_for(entry)
      ).render(tree)

      payload = {
        id: entry.id,
        collection: entry.collection,
        data: publish_data_images(entry),
        html: result.html,
        headings: result.headings,
        # Kept so `Entry#body` works in production, where entries come from
        # the index and the source file is never read. The index itself
        # leaves it out (Store#index_summary), so listings stay small.
        body: entry.body,
        digest: entry.digest,
        render_key: render_key,
        file_path: entry.file_path
      }
      @store.write_entry(entry.collection, entry.id, payload)
      payload
    end

    # The read path an `Andromeda::Entry` instance's `#html`/`#headings`
    # actually call:
    #
    # - production: read-only. A missing stored entry means the deploy-time
    #   `andromeda:build` never ran (or this entry is new since it last
    #   did) -- raises `Andromeda::BuildMissing` naming the fix, rather than
    #   silently converting in a request. Production never runs the
    #   conversion process at all.
    # - development: converts on demand when the stored digest does not
    #   match the source file's current digest (or nothing is stored yet),
    #   otherwise just reads what is already there. No mtime polling/watcher
    #   process -- staleness is only ever checked when something asks
    #   to read.
    #
    # @param entry [Andromeda::Entry]
    # @return [Hash] same shape as `#convert`'s return value.
    # @raise [Andromeda::BuildMissing] in production, when nothing is built yet.
    def fetch(entry)
      stored = @store.read_entry(entry.collection, entry.id)

      if production?
        return stored if stored

        raise Andromeda::BuildMissing.new(collection: entry.collection, id: entry.id, file_path: entry.file_path)
      end

      return stored if stored && stored[:digest] == entry.digest && stored[:render_key] == render_key

      convert(entry)
    end

    # The list-view read path behind a future `Content::Post.index` helper:
    # in production, just reads `_index.json` (never touches source files);
    # in development, does a full staleness-aware pass over the collection
    # first (via `#refresh_collection`) so the index reflects edits/deletes
    # made since the last read, without a watcher process.
    #
    # @param entry_class [Class] an Andromeda::Entry subclass.
    # @return [Array<Hash>] summaries (`id`/`data`/`headings`/`digest`/`file_path`).
    # @raise [Andromeda::BuildMissing] in production, when nothing is built yet.
    def collection_index(entry_class)
      if production?
        index = @store.read_index(entry_class.collection_name)
        return index if index

        raise Andromeda::BuildMissing.new(collection: entry_class.collection_name)
      end

      refresh_collection(entry_class)
      @store.read_index(entry_class.collection_name) || []
    end

    # Dev-mode collection refresh: re-converts only entries whose stored
    # digest is missing/stale (via `#fetch`, so an unchanged file is never
    # re-parsed), then rewrites `_index.json` from exactly the entries found
    # on disk right now -- which is also what prunes a deleted source file's
    # leftover JSON (Store#replace_collection! deletes any `<id>.json` not
    # in that set).
    #
    # @param entry_class [Class]
    # @return [Array<Hash>] every payload just fetched/converted.
    # @raise [Andromeda::BuildError] if any entry fails to convert; a schema
    #   problem across the whole collection surfaces as
    #   Andromeda::LoaderError instead, straight out of `entry_class.all`.
    def refresh_collection(entry_class)
      errors = []
      payloads = entry_class.all.to_a.filter_map do |entry|
        begin
          fetch(entry)
        rescue Andromeda::Error => e
          errors << "[#{entry_class.collection_name}] #{entry.file_path}: #{e.message}"
          nil
        end
      end

      @store.replace_collection!(entry_class.collection_name, payloads)
      raise Andromeda::BuildError, errors unless errors.empty?

      payloads
    end

    # `andromeda:build`'s per-collection unit of work (called
    # once per registered collection, or via `Pipeline.build_all`): force-
    # converts every entry (unlike `#refresh_collection`, ignoring any
    # existing stored digest -- a build always reflects *today's* renderer/
    # components, not just today's content), collecting every problem
    # instead of stopping at the first bad file, then writes whatever
    # succeeded and prunes anything stale.
    #
    # @param entry_class [Class]
    # @return [BuildResult]
    def build_collection(entry_class)
      entries =
        begin
          entry_class.source_entries
        rescue Andromeda::LoaderError => e
          return BuildResult.new(
            collection: entry_class.collection_name, converted: 0,
            errors: e.messages.map { |message| "[#{entry_class.collection_name}] #{message}" }
          )
        end

      errors = []
      payloads = entries.filter_map do |entry|
        begin
          convert(entry)
        rescue Andromeda::Error => e
          errors << "[#{entry_class.collection_name}] #{entry.file_path}: #{e.message}"
          nil
        end
      end

      @store.replace_collection!(entry_class.collection_name, payloads)
      BuildResult.new(collection: entry_class.collection_name, converted: payloads.size, errors: errors, entries: entries)
    end

    # Converts every registered collection, reporting every problem found
    # across all of them together instead of
    # aborting at the first bad collection or the first bad file within one.
    #
    # @param entry_classes [Array<Class>] defaults to every collection
    #   currently registered in Andromeda::Registry.
    # @param store [Andromeda::Store] shared across every collection, so
    #   tests (and a Rake task that wants a non-default build path) can
    #   inject one instead of every collection reaching for
    #   `Andromeda::Store.new`'s own `Andromeda.config.build_path` default.
    # @return [Array<BuildResult>] one per collection, on success.
    # @raise [Andromeda::BuildError] listing every problem found, across
    #   every collection, if any entry failed to convert or references an
    #   entry that does not exist.
    def self.build_all(entry_classes = default_entry_classes, store: Andromeda::Store.new)
      results = entry_classes.map { |entry_class| new(store: store).build_collection(entry_class) }
      errors = results.flat_map(&:errors)
      loaded = entry_classes.zip(results).filter_map { |entry_class, result| [entry_class, result.entries] if result.entries }
      errors.concat(Andromeda::References.problems(loaded.to_h))
      raise Andromeda::BuildError, errors unless errors.empty?

      results
    end

    def self.default_entry_classes
      Andromeda::Registry.collection_names.map { |name| Andromeda::Registry[name] }
    end

    private

    # What the stored HTML depends on besides the entry's own source.
    # Component partials are rendered into the HTML at conversion time, so
    # without this an edited partial would keep serving the old markup until
    # the MDX file itself changed. Partials outside `components_path` (an
    # import pointing elsewhere under app/views) are not tracked; scanning
    # every view on every development request would cost more than it saves.
    def render_key
      partials = Dir.glob(File.join(Andromeda.config.project_root, Andromeda.config.components_path, "**", "*")).sort.filter_map do |file|
        next unless File.file?(file)

        [file, File.mtime(file).to_r, File.size(file)].join(":")
      end
      Digest::SHA256.hexdigest([Andromeda::VERSION, Andromeda.config.highlight_theme, *partials].join("\n"))
    end

    def production?
      @mode == :production
    end

    # Only constructed for `.mdx` sources: a plain Markdown parse (`mdx:
    # false`) never produces an `mdxJsxFlowElement`/`mdxJsxTextElement` node
    # for the Renderer to call this on, so there is nothing to inject for
    # `.md` entries. Resolved lazily (by constant name, not a `require`) so
    # this file loads and works whether or not
    # `Andromeda::Components` has landed yet.
    # `image` attributes are published alongside the ones written in the body,
    # so a hero image declared only in frontmatter is served the same way and
    # a view never has to publish anything while handling a request.
    def publish_data_images(entry)
      base_dir = Andromeda::Registry[entry.collection]&.base_dir || File.dirname(entry.file_path)

      entry.data.each_value do |value|
        Andromeda::Assets.publish(value.path, content_root: base_dir) if value.is_a?(Andromeda::Image)
      end
      entry.data
    end

    # Images referenced from a content file are copied into the asset
    # pipeline as they are encountered, so a build only publishes what the
    # content actually uses and a deleted reference stops shipping its file.
    # Absolute and remote URLs are left alone: they are already served by
    # something else.
    def image_resolver_for(entry)
      content_root = File.dirname(entry.file_path)
      base_dir = Andromeda::Registry[entry.collection]&.base_dir || content_root

      lambda do |url, node|
        # Absolute URLs point at something already being served -- a file in
        # `public/`, another host, or an inline data URI -- so they are left
        # exactly as the author wrote them.
        next url if url.empty? || url.start_with?("/", "http://", "https://", "data:")

        source = File.expand_path(url, content_root)
        if File.file?(source)
          logical = Andromeda::Assets.publish(source, content_root: base_dir)
          next Andromeda::Assets.marker_for(logical) if logical
        end

        # `./` and `../` can only mean "relative to this file", so falling
        # back to the asset pipeline would just turn a typo into a silent 404.
        # Containment is checked first so a crafted path never learns whether
        # something outside the project exists.
        start = (node && node[:position] || {})[:start] || {}
        location = start[:line] ? "#{start[:line]}:#{start[:column]}: " : ""
        if url.start_with?("./", "../")
          inside = Andromeda::Assets.logical_path(source, content_root: base_dir)
          reason = inside ? "does not exist" : "resolves outside the project"
          raise Andromeda::Error, "#{location}image #{url.inspect} #{reason}"
        end

        # A bare path is not a file next to the content: treat it as a logical asset path so
        # images the application already ships (`app/assets/images/logo.png`,
        # written as `logo.png`) resolve through the asset pipeline and get
        # their digest, instead of 404ing in production. Without Propshaft
        # there is nothing to ask, so the path is trusted as written.
        if Andromeda::Assets.exists?(url) == false
          raise Andromeda::Error, "#{location}image #{url.inspect} is not in the asset pipeline"
        end

        Andromeda::Assets.marker_for(url)
      end
    end

    def components_for(entry, tree)
      return nil unless Andromeda::Parser.mdx?(entry.file_path)
      return nil unless defined?(Andromeda::Components)

      Andromeda::Components.new(tree: tree, path: entry.file_path, view: nil, frontmatter: entry.data)
    end
  end
end
