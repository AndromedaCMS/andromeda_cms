# frozen_string_literal: true

require "json"

module Andromeda
  # Thin Ruby wrapper around the native Sätteri bridge (`Parser.native_parse`,
  # defined in ext/andromeda_cms/src/lib.rs).
  #
  # The native method returns mdast as a JSON string rather than nested Ruby
  # objects (building `Hash`/`Array` node-by-node through the Ruby C API is
  # the slow part, not parsing — see ext/andromeda_cms/src/lib.rs), so this
  # wrapper's job is just: parse that JSON, and turn native errors into
  # `Andromeda::SyntaxError`/`Andromeda::ParserError` instances that carry the
  # caller's `path` (the native layer only knows about `source`, never which
  # file it came from).
  module Parser
    MARKDOWN_EXTENSIONS = [".md", ".markdown"].freeze
    MDX_EXTENSIONS = [".mdx"].freeze

    module_function

    # Parses Markdown or MDX `source` into an mdast tree.
    #
    # Returns a Hash with **symbol keys** (`type:`, `children:`, `position:`,
    # ...), chosen because callers pattern-match on `node[:type]` far more
    # than they serialize the tree back out, and symbol keys read like the
    # mdast-spec field names they mirror.
    #
    # @param source [String] Markdown or MDX source text.
    # @param mdx [Boolean] parse MDX syntax (JSX, expressions, ESM imports)?
    # @param path [String, nil] file path to attribute errors to; purely
    #   cosmetic (only used in raised error messages), never read from disk.
    # @raise [Andromeda::SyntaxError] if `source` cannot be parsed.
    # @raise [Andromeda::ParserError] if the native parser panics.
    def parse(source, mdx: false, path: nil)
      # Deeply nested Markdown (blockquotes, lists) produces a proportionally
      # deep JSON tree; JSON's default max_nesting (100) exists to guard
      # against adversarial input in the *decoder*, but the tree is already
      # fully materialized in memory by the time it reaches here, so there is
      # nothing left to protect against by also capping the parse depth.
      JSON.parse(native_parse(source, mdx), symbolize_names: true, max_nesting: false)
    rescue Andromeda::SyntaxError => e
      raise with_path(e, path)
    rescue Andromeda::ParserError => e
      raise with_path(e, path)
    rescue SystemStackError
      # The native layer bounds nesting, but a thread with an unusually small
      # stack could still run out first. A build log naming the file is
      # worth more than a bare "stack level too deep".
      raise with_path(Andromeda::ParserError.new("content is nested too deeply to parse"), path)
    end

    # @param path [String, Pathname] a content file's path.
    # @return [Boolean] whether `parse` should be called with `mdx: false`.
    def markdown?(path)
      MARKDOWN_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    # @param path [String, Pathname] a content file's path.
    # @return [Boolean] whether `parse` should be called with `mdx: true`.
    def mdx?(path)
      MDX_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    # Re-raises a native error with `path` attached, so editors/CI logs read
    # `app/content/blog/x.mdx:12:3: ...` instead of just `12:3: ...`.
    def with_path(error, path)
      return error if path.nil?
      return error.at(path) if error.respond_to?(:at)

      error.class.new("#{path}: #{error.message}")
    end
    private_class_method :with_path
  end
end
