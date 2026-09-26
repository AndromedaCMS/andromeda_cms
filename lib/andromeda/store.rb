# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require "date"
require "time"

module Andromeda
  # Reads and writes the `.andromeda/` build output: one JSON
  # file per entry at `<build_path>/<collection>/<id>.json`, plus one
  # `<build_path>/<collection>/_index.json` per collection holding just
  # enough of every entry (`id`/`data`/`headings`/`digest`/`file_path`) to
  # render a listing page without opening every entry's own file.
  #
  # This class only knows how to read/write that layout safely -- it has no
  # opinion on *when* to convert or re-convert a source file. That decision
  # (dev's mtime/digest check vs. production's read-only stance) is
  # Andromeda::Pipeline's job; Store is the dumb, well-tested disk layer
  # underneath it, deliberately kept ignorant of Parser/Renderer so it can be
  # tested with plain Hashes instead of real content files.
  class Store
    # @param build_path [String] absolute, or relative to Rails.root (or the
    #   current working directory outside Rails) -- same convention
    #   `Andromeda::Entry.collection`'s `base:` uses for `resolve_base`.
    def initialize(build_path: Andromeda.config.build_path)
      @build_path = resolve_build_path(build_path)
    end

    # @return [String] absolute path to the build root.
    attr_reader :build_path

    # @param collection [Symbol, String]
    # @param id [String]
    # @return [Hash, nil] Symbol-keyed payload (see Pipeline#convert for the
    #   shape), or nil if no file exists yet for this id.
    # Used by `andromeda:clobber` (and by `assets:clobber`, which it hooks
    # into) so a stale build can be thrown away wholesale.
    def clobber!
      FileUtils.rm_rf(@build_path)
      @build_path
    end

    def read_entry(collection, id)
      path = entry_path(collection, id)
      return nil unless File.file?(path)

      decode_entry(read_json(path))
    rescue JSON::ParserError
      # A reader can only ever observe a *complete* file (writes go through
      # `atomic_write`'s write-then-rename), so a parse failure here means
      # something outside this gem touched the file -- treat it the same as
      # "not built yet" rather than raising out of a request.
      nil
    end

    # @param collection [Symbol, String]
    # @return [Array<Hash>, nil] the collection's `_index.json` contents, or
    #   nil if it has never been written.
    def read_index(collection)
      path = index_path(collection)
      return nil unless File.file?(path)

      array = read_json(path)
      array.map { |summary| decode_data_field(summary) }
    rescue JSON::ParserError
      nil
    end

    # Writes one entry's JSON and folds its summary into the collection's
    # `_index.json`, without touching any other entry already in that index.
    # Used by Pipeline's dev-mode "reconvert this one stale file" path, where
    # scanning (let alone rewriting) the whole collection would be wasteful.
    #
    # @param payload [Hash] Symbol-keyed, as built by Pipeline#convert.
    # @return [Hash] `payload`, unchanged, for chaining.
    def write_entry(collection, id, payload)
      atomic_write(entry_path(collection, id), dump_json(encode_entry(payload)))
      merge_index_entry(collection, payload)
      payload
    end

    # Overwrites an entire collection at once: every payload's own file, the
    # `_index.json` built from exactly this set, and -- because this is the
    # only place that ever sees "every currently-valid id" for a collection
    # in one place -- deletes any leftover `<id>.json` that does not belong
    # to one of `payloads` (a source file deleted since the last build,
    # so its stale JSON is cleaned up).
    #
    # @param payloads [Array<Hash>]
    # @return [Array<Hash>] `payloads`, unchanged.
    def replace_collection!(collection, payloads)
      dir = collection_dir(collection)
      keep = payloads.to_h { |payload| [entry_path(collection, payload.fetch(:id)), true] }

      with_index_lock(collection) do
        prune_orphans(dir, collection, keep)
        payloads.each { |payload| atomic_write(entry_path(collection, payload.fetch(:id)), dump_json(encode_entry(payload))) }
        atomic_write(index_path(collection), dump_json(payloads.map { |payload| index_summary(payload) }))
      end

      payloads
    end

    # @param collection [Symbol, String]
    # @param id [String]
    # @return [String] absolute path, guaranteed to be inside `build_path`.
    # @raise [Andromeda::Error] if `id` (e.g. a hand-written frontmatter
    #   `slug:` -- Id.generate lets that win verbatim, unslugified) tries to
    #   escape the collection's directory via `..` segments.
    def entry_path(collection, id)
      dir = collection_dir(collection)
      path = File.expand_path(File.join(dir, "#{id}.json"))
      guard_within!(path, dir, id)
      path
    end

    # @param collection [Symbol, String]
    # @return [String] absolute path to `<build_path>/<collection>/_index.json`.
    def index_path(collection)
      File.join(collection_dir(collection), "_index.json")
    end

    private

    def resolve_build_path(build_path)
      return File.expand_path(build_path) if Pathname.new(build_path).absolute?

      File.expand_path(File.join(Andromeda.config.project_root, build_path))
    end

    def collection_dir(collection)
      dir = File.expand_path(File.join(@build_path, collection.to_s))
      guard_within!(dir, @build_path, collection)
      dir
    end

    # Shared by both `collection_dir` (guards the collection name) and
    # `entry_path` (guards the id): `path` must resolve to somewhere at or
    # under `root`, checked via `expand_path` (which collapses `..`) rather
    # than a string match on the raw value, so `id: "../../etc/passwd"`
    # cannot write outside `build_path` no matter how it is spelled.
    def guard_within!(path, root, offender)
      root_with_separator = File.expand_path(root) + File::SEPARATOR
      return if path == File.expand_path(root) || path.start_with?(root_with_separator)

      raise Andromeda::Error, "#{offender.inspect} escapes the build directory (#{root})"
    end

    def prune_orphans(dir, collection, keep)
      index = File.expand_path(index_path(collection))
      Dir.glob(File.join(dir, "**", "*.json")).each do |file|
        expanded = File.expand_path(file)
        next if expanded == index
        next if keep[expanded]

        File.delete(expanded)
      end
    end

    def merge_index_entry(collection, payload)
      with_index_lock(collection) do
        existing = read_json_array(index_path(collection))
        id = payload.fetch(:id)
        existing.reject! { |summary| summary[:id].to_s == id.to_s }
        existing << index_summary(payload)
        atomic_write(index_path(collection), dump_json(existing))
      end
    end

    # Development converts on demand from whichever Puma thread or worker
    # serves the request, so two entries of one collection can be written at
    # the same moment. Each rewrites the whole index from what it read, and
    # without this lock the later rename silently drops the earlier entry.
    # `atomic_write` alone cannot help: it keeps readers from seeing a torn
    # file, not writers from overwriting each other. A file lock rather than
    # a Mutex, because the writers may be separate processes.
    def with_index_lock(collection)
      dir = collection_dir(collection)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, ".index.lock"), File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    # `data` is encoded the same way `encode_entry` encodes it for the
    # entry's own file -- the index is read back through `decode_data_field`
    # below, and both sides need to agree on the on-disk (tagged-Hash)
    # representation for a `Date`/`Reference`/`Image` value to round-trip.
    def index_summary(payload)
      { id: payload.fetch(:id), data: self.class.encode(payload.fetch(:data)), headings: payload.fetch(:headings),
        digest: payload.fetch(:digest), file_path: payload.fetch(:file_path) }
    end

    def read_json_array(path)
      return [] unless File.file?(path)

      read_json(path)
    rescue JSON::ParserError
      []
    end

    def read_json(path)
      JSON.parse(File.read(path), symbolize_names: true)
    end

    def dump_json(object)
      JSON.pretty_generate(object)
    end

    # Never writes `path` directly: the file is built up-front in a sibling
    # temp file and only `File.rename`d into place once it is complete, so a
    # concurrent reader (another request, or a build process crashing
    # mid-write) can never observe a half-written file at `path` -- it either
    # sees the previous complete version or the new complete version, never
    # something in between.
    def atomic_write(path, content)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}-#{Thread.current.object_id}-#{rand(1_000_000)}.tmp")
      File.write(tmp, content)
      File.rename(tmp, path)
    rescue StandardError
      File.delete(tmp) if tmp && File.exist?(tmp)
      raise
    end

    def encode_entry(payload)
      payload.merge(collection: payload[:collection].to_s, data: self.class.encode(payload[:data]))
    end

    def decode_entry(payload)
      payload.merge(collection: payload[:collection]&.to_sym, data: self.class.decode(payload[:data]))
    end

    def decode_data_field(payload)
      payload.merge(data: self.class.decode(payload[:data]))
    end

    class << self
      # Frontmatter `data` can hold types JSON has no native representation
      # for (`Date`, `Andromeda::Reference`, `Andromeda::Image`) --
      # each is written as a small tagged Hash (`{__type:, ...}`) so `decode`
      # can rebuild the exact same Ruby object on the way back out, keeping
      # the store's round trip (`convert -> write -> read`) lossless for
      # every type `Andromeda::Schema` can produce.
      def encode(value)
        case value
        when Andromeda::Reference then { __type: :reference, collection: value.collection, id: value.id }
        when Andromeda::Image then { __type: :image, path: value.path, relative_path: value.relative_path, asset: value.asset }
        when DateTime then { __type: :datetime, value: value.iso8601 }
        when Time then { __type: :time, value: value.iso8601 }
        when Date then { __type: :date, value: value.iso8601 }
        when Array then value.map { |element| encode(element) }
        when Hash then value.transform_values { |element| encode(element) }
        else value
        end
      end

      def decode(value)
        case value
        when Hash
          value.key?(:__type) ? decode_tagged(value) : value.transform_values { |element| decode(element) }
        when Array
          value.map { |element| decode(element) }
        else
          value
        end
      end

      private

      def decode_tagged(value)
        case value[:__type].to_s
        when "reference" then Andromeda::Reference.new(collection: value[:collection].to_sym, id: value[:id])
        when "image" then Andromeda::Image.new(path: value[:path], relative_path: value[:relative_path], asset: value[:asset])
        when "datetime" then DateTime.iso8601(value[:value])
        when "time" then Time.iso8601(value[:value])
        when "date" then Date.iso8601(value[:value])
        else value
        end
      end
    end
  end
end
