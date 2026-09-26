# frozen_string_literal: true

require "digest"

module Andromeda
  # The v0 File loader: expands `base`/`pattern` into a list
  # of files, splits and validates each one's frontmatter, computes its id,
  # and builds `entry_class` instances. ActiveRecord/HTTP loaders are
  # out of scope for v0 -- content is file-only for now, so this is the
  # only implementation; the shape below (`#load` returning entries,
  # everything else private) is what a second loader would need to match.
  #
  # Every problem across every file is collected into one
  # `Andromeda::LoaderError` instead of raising on the first bad file --
  # same "report everything in one pass" choice `Schema#validate` makes, for
  # the same reason: nobody wants to fix-and-rerun one file at a time.
  class Loader
    # @param entry_class [Class] an Andromeda::Entry subclass; used both to
    #   construct instances and to read its declared `schema`.
    # @param base [String] absolute path to the collection's content root.
    # @param pattern [String] a Dir.glob pattern, relative to `base`.
    # @param schema [Andromeda::Schema]
    def initialize(entry_class:, base:, pattern:, schema:)
      @entry_class = entry_class
      @base = base
      @pattern = pattern
      @schema = schema
    end

    # @return [Array<Andromeda::Entry>]
    # @raise [Andromeda::LoaderError] if any file fails to validate/parse,
    #   or if two files resolve to the same id.
    def load
      root = File.expand_path(@base)
      paths = Dir.glob(File.join(root, @pattern)).select { |path| File.file?(path) }.sort

      messages = []
      seen_ids = {}
      entries = []

      paths.each do |path|
        entry, error = build_entry(path, root)
        if error
          messages << error
          next
        end

        if seen_ids.key?(entry.id)
          messages << "#{path}: duplicate id #{entry.id.inspect} (already used by #{seen_ids[entry.id]})"
          next
        end

        seen_ids[entry.id] = path
        entries << entry
      end

      raise Andromeda::LoaderError, messages unless messages.empty?

      entries
    end

    private

    # @return [Array(Andromeda::Entry, nil), Array(nil, String)]
    def build_entry(path, root)
      source = File.read(path)
      frontmatter, body = Andromeda::Frontmatter.parse(source, path: path)

      result = @schema.validate(frontmatter, path: path, entry_path: path, content_root: root)
      unless result.valid?
        return [nil, result.problems.map { |problem| "#{path}: #{problem.message}" }.join("\n")]
      end

      relative_path = path.delete_prefix(root + File::SEPARATOR)
      id = Andromeda::Id.generate(relative_path, slug: frontmatter["slug"])

      entry = @entry_class.new(
        id: id,
        collection: @entry_class.collection_name,
        data: result.data,
        body: body,
        file_path: path,
        # SHA-256 of the whole raw file (frontmatter included), not just the
        # body: a frontmatter-only edit (e.g. fixing a typo in `title`)
        # should invalidate any cache keyed on this just as much as a body
        # edit would -- `digest` is a cache key for the
        # content, and the frontmatter is as much "the content" as the
        # body is.
        digest: Digest::SHA256.hexdigest(source)
      )
      [entry, nil]
    rescue Andromeda::SyntaxError => e
      [nil, e.message]
    end
  end
end
