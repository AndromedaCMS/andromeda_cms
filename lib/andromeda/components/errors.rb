# frozen_string_literal: true

module Andromeda
  class Components
    # Raised when a component tag resolves to a partial name (by explicit
    # registration, import path, or naming convention) but no such partial
    # exists on disk. Names the tag, the content file, the line, and the
    # exact path to create so the error is actionable straight out
    # of a build log or a development error page, without having to go
    # spelunking through the resolution rules to figure out what Andromeda
    # was even looking for.
    class MissingPartialError < Andromeda::Error
      attr_reader :tag_name, :path, :line, :expected_path

      def initialize(tag_name, path:, line:, expected_path:)
        @tag_name = tag_name
        @path = path
        @line = line
        @expected_path = expected_path

        location = [path, line].compact.join(":")
        super(
          "#{location}: <#{tag_name}> has no matching partial. Create #{expected_path} " \
          "(e.g. `rails g andromeda:component #{tag_name}`), register it explicitly with " \
          "`Andromeda::Components.register(#{tag_name.to_s.inspect}, \"partial/path\")`, or " \
          "import it from a path that points at an existing partial."
        )
      end
    end

    # Raised for a member-expression tag name (`<Tabs.Item>`) that
    # was not explicitly registered. Convention-based resolution can't turn
    # a dotted name into a partial path, and guessing would be more
    # surprising than just saying so -- named-slot components (the
    # `Tabs`/`Fragment slot=` pattern) cover the common case this syntax is
    # usually reaching for.
    class InvalidComponentNameError < Andromeda::Error
      attr_reader :tag_name, :path, :line

      def initialize(tag_name, path:, line:)
        @tag_name = tag_name
        @path = path
        @line = line

        location = [path, line].compact.join(":")
        super(
          "#{location}: <#{tag_name}> looks like a member expression (e.g. `Tabs.Item`), " \
          "which Andromeda does not resolve by naming convention in v0 -- register it " \
          "explicitly with `Andromeda::Components.register(#{tag_name.to_s.inspect}, " \
          "\"partial/path\")`"
        )
      end
    end

    # Raised for a `{...}` expression that is neither a literal,
    # a `frontmatter.x` reference, nor a comment -- the
    # v0 static-expression subset. Everything else (`.map()`,
    # ternaries, template interpolation, arrow functions, `await`, ...) is
    # explicitly out of scope, and silently dropping it would hide content
    # bugs, so this raises naming the file/line rather than degrading
    # quietly.
    class UnsupportedExpressionError < Andromeda::Error
      attr_reader :source, :path, :line, :column

      def initialize(source, path:, line:, column:)
        @source = source
        @path = path
        @line = line
        @column = column

        location = [path, line].compact.join(":")
        super(
          "#{location}: unsupported MDX expression `{#{source}}` -- only literals, " \
          "`frontmatter.x` references, and comments are supported"
        )
      end
    end

    # Raised when there is no Rails renderer to hand a partial to -- either
    # `ApplicationController` is not defined (Rails is not loaded / not
    # booted yet) and no `view:` was passed explicitly to
    # `Andromeda::Components.new`. Components render through
    # `ApplicationController.renderer`; there is no non-Rails fallback in
    # v0 (a plain ActionView::Base renderer setup is enough of a project on
    # its own -- view paths, compiled template caching, helpers -- that it
    # is deferred rather than half-done here).
    class NoRendererAvailableError < Andromeda::Error
      def initialize(path)
        super(
          "no Rails renderer available to render MDX components in " \
          "#{path || "(unknown file)"} -- define ApplicationController, or pass `view:` " \
          "explicitly to Andromeda::Components.new"
        )
      end
    end
  end
end
