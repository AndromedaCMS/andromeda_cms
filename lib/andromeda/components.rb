# frozen_string_literal: true

require_relative "components/errors"
require_relative "components/import_scanner"
require_relative "components/static_expression"

module Andromeda
  # The `components:` collaborator `Andromeda::Renderer` delegates
  # MDX component tags to (`#render(name, attributes, children_html, node)`,
  # see renderer.rb's `render_component`). Resolves a tag name to a Rails
  # partial under `Andromeda.config.components_path` and
  # renders it with `ApplicationController.renderer`, turning props
  # into locals (camelCase -> snake_case), the already-rendered
  # children into a `content` local, and named slots into locals of their
  # own.
  #
  # One instance is scoped to a single content file: `tree` is needed to
  # collect its import bindings once up front (rather than re-scanning per
  # tag), and `path`/`frontmatter` exist purely to make error messages and
  # `{frontmatter.x}` expressions file-specific.
  class Components
    # @param tree [Hash] the mdast root for the file being rendered, so
    #   import bindings (`mdxjsEsm` nodes) can be collected once up front.
    # @param path [String, nil] the content file's path, for error messages.
    # @param view [#render, nil] anything responding to
    #   `#render(partial:, locals:)`. Defaults to
    #   `ApplicationController.renderer` (a fresh instance per `Components`,
    #   since renderer instances are not meant to be reused across
    #   concurrent builds) when
    #   Rails is loaded; `nil` outside Rails unless the caller supplies one,
    #   in which case rendering a component raises `NoRendererAvailableError`
    #   (see components/errors.rb -- there is no non-Rails ActionView
    #   fallback in v0).
    # @param frontmatter [Hash, nil] the entry's validated frontmatter data,
    #   consulted for `{frontmatter.x}` expressions. Not part of
    #   the original contract this class was written against, so it defaults
    #   to `{}` and callers that don't pass it simply get `nil` back for
    #   every `frontmatter.x` reference instead of an error.
    def initialize(tree:, path: nil, view: nil, frontmatter: {})
      @tree = tree
      @path = path
      @frontmatter = frontmatter || {}
      @view = view || default_view
      @imports = ImportScanner.scan(tree)
    end

    # @param name [String] the JSX tag name, e.g. `"Callout"` or
    #   `"Tabs.Item"` (member expressions reach here too -- see
    #   `resolve_partial`).
    # @param _attributes [Hash] the renderer's own already-evaluated
    #   attribute hash. Unused here: it cannot tell a genuine string prop
    #   apart from a non-literal expression's raw-source fallback (both are
    #   plain Ruby Strings by the time they reach it), so props are instead
    #   computed straight from `node[:attributes]` below, which still has
    #   that distinction (`mdxJsxAttributeValueExpression` vs a bare
    #   String). Kept in the signature only to match the contract the
    #   renderer already calls this with.
    # @param children_html [String] the tag's children, already rendered to
    #   HTML by the renderer (Markdown included).
    # @param node [Hash] the raw `mdxJsxFlowElement`/`mdxJsxTextElement` mdast
    #   node, needed for its attributes, children (for slot-splitting), and
    #   source position (for error messages).
    # @return [String] the rendered partial's HTML.
    def render(name, _attributes, children_html, node)
      # `<Fragment>` (explicit tag, not the `<>...</>` shorthand the renderer
      # already unwraps on its own) is JSX's no-op grouping wrapper -- most
      # commonly seen as `<Fragment slot="header">...</Fragment>`.
      # It never resolves to a partial; it passes its children through
      # unchanged. This also matters structurally: the renderer has already
      # recursively rendered every nested component tag (including this
      # one) via `render_children` *before* calling the parent's
      # `#render` below, so by the time `build_slots_and_content` inspects
      # a slotted `<Fragment>` child for its own raw nodes, this tag itself
      # must not have tried (and failed) to resolve a "Fragment" partial.
      return html_safe(children_html) if name == "Fragment"

      raise NoRendererAvailableError, @path unless @view

      partial = resolve_partial(name, node)
      locals = build_props(node).merge(build_slots_and_content(node, children_html))

      render_partial(partial, locals, name: name, node: node)
    end

    # The renderer's `render_expression` calls this for every
    # `mdxFlowExpression`/`mdxTextExpression` it cannot resolve as a bare
    # literal or comment on its own (see renderer.rb) -- i.e. anything left
    # that specifically needs frontmatter or file/line context to evaluate
    # or to error out on, which only this class (not the stateless
    # `Renderer`) has.
    #
    # @param source [String] raw text between `{` and `}`.
    # @param line [Integer, nil] / @param column [Integer, nil] the
    #   expression node's source position, for the error message.
    # @return [Object] the evaluated value.
    # @raise [UnsupportedExpressionError]
    def evaluate_expression(source, line: nil, column: nil)
      StaticExpression.evaluate(source, frontmatter: @frontmatter)
    rescue StaticExpression::UnsupportedExpressionError
      raise UnsupportedExpressionError.new(source, path: @path, line: line, column: column)
    end

    class << self
      # Explicit registration (top precedence tier): `name` can be
      # any tag spelling, including a member expression (`"Tabs.Item"`)
      # that naming-convention resolution refuses to guess at.
      #
      # @param name [String, Symbol]
      # @param partial [String] a Rails partial path, e.g.
      #   `"content_components/callout"`.
      def register(name, partial)
        registrations[name.to_s] = partial.to_s
      end

      # @return [String, nil]
      def registered(name)
        registrations[name.to_s]
      end

      # Test-only reset, mirroring `Andromeda::Registry.clear!`.
      def clear_registrations!
        @registrations = {}
      end

      # camelCase -> snake_case, used for prop names, slot names, and
      # the naming-convention partial lookup (`YouTube` -> `you_tube`).
      # Hand-rolled rather than pulled in from ActiveSupport's
      # `String#underscore` so this file has no load-order dependency on
      # `active_support/core_ext` being required anywhere -- the algorithm
      # is the same one ActiveSupport::Inflector uses for the common case.
      #
      # @param name [String, Symbol]
      # @return [String]
      def underscore(name)
        name.to_s
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z0-9])([A-Z])/, '\1_\2')
            .tr("-", "_")
            .downcase
      end

      private

      def registrations
        @registrations ||= {}
      end
    end

    private

    # @return [String, nil]
    def resolve_partial(name, node)
      return self.class.registered(name) if self.class.registered(name)

      if name.include?(".")
        position = node_position(node)
        raise InvalidComponentNameError.new(name, path: @path, line: position[:line])
      end

      import_path = @imports[name]
      return import_path if import_path && partial_exists?(import_path)

      convention_partial(name)
    end

    def convention_partial(name)
      base = Andromeda.config.components_path.sub(%r{\Aapp/views/}, "")
      "#{base}/#{self.class.underscore(name)}"
    end

    # @return [Hash{Symbol => Object}] props, camelCase -> snake_case,
    #   values evaluated per `StaticExpression` (raising for a
    #   non-literal/non-frontmatter expression, per the components
    #   contract -- unlike `Renderer#jsx_attributes`, which silently falls
    #   back to the raw source for the renderer's own, frontmatter-less use
    #   case).
    def build_props(node)
      (node[:attributes] || []).each_with_object({}) do |attribute, props|
        next unless attribute[:type] == "mdxJsxAttribute"

        key = self.class.underscore(attribute[:name]).to_sym
        props[key] = attribute_value(attribute[:value], node)
      end
    end

    def attribute_value(value, node)
      case value
      when nil then true # bare boolean prop: <Toggle enabled />
      when String then value
      when Hash
        return value unless value[:type] == "mdxJsxAttributeValueExpression"

        evaluate_prop_expression(value[:value], node)
      else
        value
      end
    end

    def evaluate_prop_expression(source, node)
      StaticExpression.evaluate(source, frontmatter: @frontmatter)
    rescue StaticExpression::UnsupportedExpressionError
      position = node_position(node)
      raise UnsupportedExpressionError.new(source, path: @path, line: position[:line], column: position[:column])
    end

    # @return [Hash{Symbol => String}] `{content: ...}` plus one entry per
    #   named slot. When no child carries a `slot` attribute this
    #   is just `{content: children_html}` -- the common case reuses the
    #   renderer's already-rendered `children_html` instead of re-rendering
    #   anything. Slotted content needs its own render pass because
    #   `children_html` is one flattened string with no seam between "goes
    #   in a slot" and "goes in `content`".
    def build_slots_and_content(node, children_html)
      children = node[:children] || []
      slotted, rest = children.partition { |child| slot_name_of(child) }
      return { content: html_safe(children_html) } if slotted.empty?

      locals = slotted.each_with_object({}) do |child, out|
        key = self.class.underscore(slot_name_of(child)).to_sym
        out[key] = render_subtree(child[:children] || [])
      end
      locals[:content] = render_subtree(rest)
      locals
    end

    # `<Fragment slot="header">`/`<div slot="footer">`: any direct JSX child
    # element carrying a `slot="..."` attribute names a slot; the wrapper
    # element itself (Fragment or otherwise) is not rendered, only its
    # children -- matching Astro's named-slot semantics, where `slot` is a
    # routing instruction, not a real DOM node.
    def slot_name_of(child)
      return nil unless %w[mdxJsxFlowElement mdxJsxTextElement].include?(child[:type])

      attribute = (child[:attributes] || []).find { |a| a[:type] == "mdxJsxAttribute" && a[:name] == "slot" }
      attribute && attribute[:value].is_a?(String) ? attribute[:value] : nil
    end

    # A fresh child-nodes-only "document" handed back through the full
    # renderer (with `self` as its `components:` collaborator, so nested
    # components inside a slot still resolve). Note this resets heading/
    # footnote bookkeeping for the subtree (`Renderer#render` is
    # per-call-stateless by design -- see renderer.rb) -- slot content
    # containing a heading would get a slug numbered from scratch rather
    # than continuing the parent document's sequence. Slots holding
    # headings are rare enough in practice that this is an acceptable v0
    # gap rather than a reason to restructure the renderer's per-document
    # state around mid-tree re-entrancy.
    def render_subtree(children_nodes)
      html_safe(sub_renderer.render({ type: "root", children: children_nodes }).html)
    end

    def sub_renderer
      @sub_renderer ||= Andromeda::Renderer.new(components: self)
    end

    def render_partial(partial, locals, name:, node:)
      annotate_before = suppress_view_annotation
      begin
        @view.render(partial: partial, locals: locals).html_safe
      rescue ActionView::MissingTemplate
        raise missing_partial_error(name, node, partial)
      ensure
        restore_view_annotation(annotate_before)
      end
    end

    # Rails' dev-mode "annotate rendered views with
    # filenames" feature wraps every partial (including ones rendered
    # through `ApplicationController.renderer`, with no live request) in
    # `<!-- BEGIN ... -->`/`<!-- END ... -->` HTML comments. Fine for a
    # normal request/response cycle; fatal here, since this HTML is baked
    # once into `.andromeda/*.json` and served forever after -- the comments
    # would leak into production output. Toggling the *class* attribute
    # (`ActionView::Base.annotate_rendered_view_with_filenames=`) is what
    # actually controls this, not
    # `Rails.application.config.action_view.annotate_rendered_view_with_filenames`
    # (that config value is only read once, at initialization, to set the
    # class attribute's *initial* value).
    def suppress_view_annotation
      return nil unless defined?(ActionView::Base)

      previous = ActionView::Base.annotate_rendered_view_with_filenames
      ActionView::Base.annotate_rendered_view_with_filenames = false
      previous
    end

    def restore_view_annotation(previous)
      return unless defined?(ActionView::Base)

      ActionView::Base.annotate_rendered_view_with_filenames = previous
    end

    def missing_partial_error(name, node, partial)
      position = node_position(node)
      MissingPartialError.new(name, path: @path, line: position[:line], expected_path: expected_partial_path(partial))
    end

    def expected_partial_path(partial)
      dir = File.dirname(partial)
      base = File.basename(partial)
      dir == "." ? "app/views/_#{base}.html.erb" : "app/views/#{dir}/_#{base}.html.erb"
    end

    # File-existence check under the conventional Rails view root, used
    # only to decide whether an import path "points at a partial"
    # and should therefore win over naming-convention resolution. This
    # deliberately doesn't ask `@view`/`ActionView::LookupContext` (which
    # would also honor custom `prepend_view_path`/engine view paths) --
    # `andromeda:import_astro` always rewrites import paths to plain
    # `app/views`-relative partial paths, so the simpler disk check is
    # enough for what v0 needs to resolve, and an actually-missing partial
    # still gets a clear error at render time either way.
    def partial_exists?(partial)
      dir = File.dirname(partial)
      base = File.basename(partial)
      views_root = File.join(Andromeda.config.project_root, "app/views")

      %w[html.erb erb html.slim slim html.haml haml].any? do |ext|
        candidate = File.expand_path(File.join(views_root, dir, "_#{base}.#{ext}"))
        # ActionView would refuse to render a partial outside app/views
        # anyway; checking first keeps an `import` of `../../config/x` from
        # probing whether arbitrary files exist.
        candidate.start_with?(views_root + File::SEPARATOR) && File.exist?(candidate)
      end
    end

    def node_position(node)
      position = node[:position] || {}
      start = position[:start] || {}
      { line: start[:line], column: start[:column] }
    end

    def html_safe(string)
      string.to_s.html_safe
    end

    # `ApplicationController.renderer`. A fresh instance (rather
    # than reusing a shared one) per `Components`, and `http_host` set
    # explicitly, because there is no live request to supply one -- a
    # partial calling a URL helper without it can raise or build a bogus
    # host otherwise.
    def default_view
      return nil unless defined?(::ApplicationController)

      ::ApplicationController.renderer.new(http_host: "andromeda-build.internal")
    end
  end
end
