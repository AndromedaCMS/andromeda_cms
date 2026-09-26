# frozen_string_literal: true

module Andromeda
  class Renderer
    # Raised when MDX source uses a capitalized tag (an MDX *component*, not
    # a lowercase HTML element) but no `components:` collaborator was given
    # to render it. Kept in this file rather than `lib/andromeda/errors.rb`
    # so the renderer's error surface stays independent from the schema /
    # parser error hierarchy being developed alongside it; it still inherits
    # from `Andromeda::Error` so host apps can rescue everything the gem
    # raises with one class -- the error must name the tag and where
    # to create the missing partial, which is the Rails-side collaborator's
    # job once one exists -- this class carries the tag name and source
    # location, since that is all the renderer itself knows).
    class MissingComponentError < Andromeda::Error
      attr_reader :tag_name, :line, :column

      def initialize(tag_name, line:, column:)
        @tag_name = tag_name
        @line = line
        @column = column
        location = line ? "#{line}:#{column}: " : ""
        super("#{location}no component collaborator registered for <#{tag_name}> " \
              "(pass `components:` to Andromeda::Renderer.new to handle MDX component tags)")
      end
    end

    # Raised if a `yaml`/`toml` mdast node ever reaches the renderer.
    # `Andromeda::Frontmatter` is supposed to strip frontmatter *before* the
    # body is handed to `Andromeda::Parser` (see frontmatter.rb), so these
    # node types should be structurally impossible here; this exists so a
    # future change that skips that step fails loudly instead of silently
    # rendering (or silently dropping) a frontmatter block as content.
    class UnexpectedFrontmatterNodeError < Andromeda::Error
      def initialize(node_type)
        super("unexpected #{node_type.inspect} node reached Renderer -- frontmatter must be " \
              "stripped by Andromeda::Frontmatter before the body is parsed")
      end
    end

    # Raised for mdast node types the native parser is configured to never
    # emit (directives, description lists, superscript/subscript -- see the
    # `options_for` comment in ext/andromeda_cms/src/lib.rs) but that
    # `nodes.rs` can still decode. Guards against a future options change
    # silently reaching a renderer branch that was never written for it.
    class UnsupportedNodeError < Andromeda::Error
      def initialize(node_type)
        super("no renderer for mdast node type #{node_type.inspect}")
      end
    end
  end
end
