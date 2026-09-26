# frozen_string_literal: true

require "cgi"
require_relative "slugger"
require_relative "renderer/errors"
require_relative "renderer/code_highlighter"
require_relative "renderer/literal_expression"

module Andromeda
  # Turns an mdast tree (as produced by `Andromeda::Parser.parse`) into HTML,
  # matching Astro's default rendering choices closely enough to display
  # copied-over content correctly -- displaying it correctly is the goal,
  # not a byte-exact match.
  #
  # One instance is stateless across calls to `#render` (each call resets
  # its own heading/footnote/definition bookkeeping), so a single Renderer
  # can be reused for many documents; what varies per host app is the
  # `components:`/`link_resolver:`/`image_resolver:` collaborators, not
  # per-document state.
  class Renderer
    # `render` returns one of these: `html` is the full rendered document,
    # `headings` is `[{depth:, slug:, text:}, ...]` in document order --
    # the same shape Astro's `render()` result carries, for a
    # future `toc` helper to walk without re-parsing the tree.
    Result = Struct.new(:html, :headings, keyword_init: true)

    # @param components [#render, nil] receives `(tag_name, attributes,
    #   children_html, node)` for every MDX component tag (capitalized, or
    #   containing a `.`) and must return an HTML string. `nil` (the
    #   default) means MDX component tags raise `MissingComponentError`
    #   instead -- the real Rails-partial-backed collaborator is wired in
    #   elsewhere; tests here use a stub that records calls.
    # @param link_resolver [#call, nil] `(url, node) -> url`, applied to
    #   every `link`/`linkReference` URL. Identity by default; relative-link
    #   and Propshaft resolution are plugged in here elsewhere.
    # @param image_resolver [#call, nil] `(url, node) -> url`, same shape,
    #   applied to every `image`/`imageReference` URL.
    def initialize(components: nil, link_resolver: nil, image_resolver: nil)
      @components = components
      @link_resolver = link_resolver || ->(url, _node) { url }
      @image_resolver = image_resolver || ->(url, _node) { url }
    end

    # @param tree [Hash] an mdast root node (symbol keys, as
    #   `Andromeda::Parser.parse` returns).
    # @return [Result]
    def render(tree)
      # Per-render state. A fresh Slugger means heading ids restart at
      # `-1`/`-2` for every document, matching Astro's "one Slugger per
      # file" behaviour rather than accumulating across renders.
      @slugger = Slugger.new
      @headings = []
      @definitions = {}
      @footnote_definitions = {}
      @footnote_order = []
      @footnote_ref_counts = Hash.new(0)

      # `definition`/`footnoteDefinition` nodes can appear anywhere in the
      # tree (often after the text that references them), so references
      # need every definition collected before the single rendering pass
      # below reaches them.
      collect_definitions_and_footnotes(tree)

      html = render_node(tree)
      html += render_footnotes_section if @footnote_order.any?

      Result.new(html: html, headings: @headings)
    end

    # @param text [String, nil]
    # @return [String] `text` with `&`, `<`, `>`, `"`, `'` entity-escaped.
    #   Shared by text content and attribute values -- escaping quotes in
    #   plain text is harmless, and using one helper everywhere means a raw
    #   node's `:value` is never accidentally escaped twice.
    def self.escape_html(text)
      CGI.escapeHTML(text.to_s)
    end

    class << self
      alias_method :escape_attr, :escape_html
    end

    private

    def collect_definitions_and_footnotes(node)
      case node[:type]
      when "definition"
        @definitions[node[:identifier].to_s.downcase] = node
      when "footnoteDefinition"
        @footnote_definitions[node[:identifier].to_s.downcase] = node
      end

      (node[:children] || []).each { |child| collect_definitions_and_footnotes(child) }
    end

    def render_children(node)
      (node[:children] || []).map { |child| render_node(child) }.join
    end

    def render_node(node)
      case node[:type]
      when "root" then render_children(node)
      when "paragraph" then "<p>#{render_children(node)}</p>\n"
      when "heading" then render_heading(node)
      when "thematicBreak" then "<hr />\n"
      when "blockquote" then "<blockquote>\n#{render_children(node)}</blockquote>\n"
      when "list" then render_list(node)
      # Reachable only if a `listItem` is ever walked outside `render_list`
      # (e.g. a future caller rendering a subtree directly); `spread: true`
      # is the safe default since it never drops a `<p>` that should stay.
      when "listItem" then render_list_item(node, spread: true)
      when "code" then CodeHighlighter.render(node[:value].to_s, node[:lang])
      when "inlineCode" then "<code>#{Renderer.escape_html(node[:value])}</code>"
      # No sanitization: raw HTML is passed through unchanged, matching
      # Astro -- content is trusted,
      # developer-authored input, not user-submitted.
      when "html" then node[:value].to_s
      when "yaml", "toml" then raise UnexpectedFrontmatterNodeError, node[:type]
      when "text" then Renderer.escape_html(node[:value])
      when "emphasis" then "<em>#{render_children(node)}</em>"
      when "strong" then "<strong>#{render_children(node)}</strong>"
      when "delete" then "<del>#{render_children(node)}</del>"
      when "break" then "<br />\n"
      when "link" then render_link(node)
      when "image" then render_image(node)
      when "definition" then "" # not visible output; only a reference target
      when "linkReference" then render_link_reference(node)
      when "imageReference" then render_image_reference(node)
      when "footnoteReference" then render_footnote_reference(node)
      when "footnoteDefinition" then "" # rendered once, at the end -- see render_footnotes_section
      when "table" then render_table(node)
      # Only reached if walked outside render_table (which renders rows/
      # cells directly to apply column alignment); dispatch here still
      # produces sane output rather than raising.
      when "tableRow", "tableCell" then render_children(node)
      when "math" then %(<div class="math math-display">#{Renderer.escape_html(node[:value])}</div>)
      when "inlineMath" then %(<span class="math math-inline">#{Renderer.escape_html(node[:value])}</span>)
      when "mdxJsxFlowElement", "mdxJsxTextElement" then render_jsx_element(node)
      when "mdxFlowExpression", "mdxTextExpression" then render_expression(node)
      when "mdxjsEsm" then "" # import/export bindings consumed elsewhere; nothing to render here
      else
        raise UnsupportedNodeError, node[:type]
      end
    end

    def render_heading(node)
      text = heading_text(node)
      slug = @slugger.slug(text)
      @headings << { depth: node[:depth], slug: slug, text: text }
      depth = node[:depth]
      "<h#{depth} id=\"#{Renderer.escape_attr(slug)}\">#{render_children(node)}</h#{depth}>\n"
    end

    # Only `text` nodes
    # contribute characters; other leaf nodes (`html`, `break`, `inlineCode`,
    # ...) contribute nothing even though they carry a `:value`, and other
    # parent nodes (`emphasis`, `strong`, ...) contribute their descendant
    # text nodes by recursing into `:children`.
    def heading_text(node)
      return node[:value].to_s if node[:type] == "text"

      (node[:children] || []).map { |child| heading_text(child) }.join
    end

    def render_list(node)
      tag = node[:ordered] ? "ol" : "ul"
      start_attr = node[:ordered] && node[:start] && node[:start] != 1 ? %( start="#{node[:start]}") : ""
      items = (node[:children] || []).map { |item| render_list_item(item, spread: node[:spread]) }.join
      "<#{tag}#{start_attr}>\n#{items}</#{tag}>\n"
    end

    def render_list_item(node, spread:)
      checked = node[:checked]
      class_attr = checked.nil? ? "" : ' class="task-list-item"'
      checkbox =
        if checked.nil?
          ""
        else
          %(<input type="checkbox" disabled=""#{checked ? ' checked=""' : ""} /> )
        end

      children = node[:children] || []
      body =
        if spread
          render_children(node)
        else
          # Tight lists (CommonMark): a listItem's direct paragraph children
          # render without a `<p>` wrapper; any other child (nested list,
          # blockquote, ...) still renders normally.
          children.map { |child| child[:type] == "paragraph" ? render_children(child) : render_node(child) }.join
        end

      "<li#{class_attr}>#{checkbox}#{body}</li>\n"
    end

    def render_link(node)
      url = @link_resolver.call(node[:url].to_s, node)
      title_attr = node[:title] ? %( title="#{Renderer.escape_attr(node[:title])}") : ""
      %(<a href="#{Renderer.escape_attr(url)}"#{title_attr}>#{render_children(node)}</a>)
    end

    def render_image(node)
      url = @image_resolver.call(node[:url].to_s, node)
      title_attr = node[:title] ? %( title="#{Renderer.escape_attr(node[:title])}") : ""
      %(<img src="#{Renderer.escape_attr(url)}" alt="#{Renderer.escape_attr(node[:alt])}"#{title_attr} />)
    end

    def render_link_reference(node)
      definition = @definitions[node[:identifier].to_s.downcase]
      return render_children(node) unless definition

      url = @link_resolver.call(definition[:url].to_s, node)
      title_attr = definition[:title] ? %( title="#{Renderer.escape_attr(definition[:title])}") : ""
      %(<a href="#{Renderer.escape_attr(url)}"#{title_attr}>#{render_children(node)}</a>)
    end

    def render_image_reference(node)
      definition = @definitions[node[:identifier].to_s.downcase]
      return "" unless definition

      url = @image_resolver.call(definition[:url].to_s, node)
      title_attr = definition[:title] ? %( title="#{Renderer.escape_attr(definition[:title])}") : ""
      %(<img src="#{Renderer.escape_attr(url)}" alt="#{Renderer.escape_attr(node[:alt])}"#{title_attr} />)
    end

    def render_footnote_reference(node)
      id = node[:identifier].to_s.downcase
      @footnote_order << id unless @footnote_order.include?(id)
      index = @footnote_order.index(id) + 1

      @footnote_ref_counts[id] += 1
      suffix = @footnote_ref_counts[id] == 1 ? "" : "-#{@footnote_ref_counts[id]}"

      %(<sup><a href="#user-content-fn-#{id}" id="user-content-fnref-#{id}#{suffix}" ) +
        %(data-footnote-ref="" aria-describedby="footnote-label">#{index}</a></sup>)
    end

    def render_footnotes_section
      items = @footnote_order.filter_map { |id|
        definition = @footnote_definitions[id]
        render_footnote_definition_li(id, definition) if definition
      }.join

      "<section data-footnotes=\"\" class=\"footnotes\">\n" \
        "<h2 id=\"footnote-label\" class=\"sr-only\">Footnotes</h2>\n" \
        "<ol>\n#{items}</ol>\n</section>\n"
    end

    def render_footnote_definition_li(id, node)
      children = node[:children] || []
      backrefs = footnote_backrefs(id)
      body_parts = children.map { |child| render_node(child) }

      if children.last && children.last[:type] == "paragraph" && body_parts.last.end_with?("</p>\n")
        body_parts[-1] = "#{body_parts.last.sub(/<\/p>\n\z/, "")}#{backrefs}</p>\n"
      else
        body_parts << "<p>#{backrefs}</p>\n"
      end

      "<li id=\"user-content-fn-#{id}\">\n#{body_parts.join}</li>\n"
    end

    def footnote_backrefs(id)
      count = @footnote_ref_counts[id]
      return "" if count.nil? || count.zero?

      (1..count).map { |n|
        suffix = n == 1 ? "" : "-#{n}"
        label = n == 1 ? "Back to reference 1" : "Back to reference 1-#{n}"
        %( <a href="#user-content-fnref-#{id}#{suffix}" data-footnote-backref="" ) +
          %(aria-label="#{label}" class="data-footnote-backref">↩</a>)
      }.join
    end

    def render_table(node)
      aligns = node[:align] || []
      rows = node[:children] || []
      return "<table></table>\n" if rows.empty?

      header = render_table_row(rows[0], aligns, header: true)
      body = rows[1..].map { |row| render_table_row(row, aligns, header: false) }.join
      "<table>\n<thead>\n#{header}</thead>\n<tbody>\n#{body}</tbody>\n</table>\n"
    end

    def render_table_row(node, aligns, header:)
      tag = header ? "th" : "td"
      cells = (node[:children] || []).each_with_index.map { |cell, index|
        align = aligns[index]
        style_attr = align ? %( style="text-align:#{align}") : ""
        "<#{tag}#{style_attr}>#{render_children(cell)}</#{tag}>"
      }.join
      "<tr>#{cells}</tr>\n"
    end

    def render_jsx_element(node)
      name = node[:name]
      return render_children(node) if name.nil? # fragment: <>...</>

      component_tag?(name) ? render_component(node, name) : render_html_element(node, name)
    end

    # MDX's own rule: a tag is a component reference (not a plain HTML
    # element) if its name starts with an uppercase letter or contains a
    # `.` (member expression, e.g. `<Tabs.Item>`).
    def component_tag?(name)
      name.start_with?(/[A-Z]/) || name.include?(".")
    end

    def render_component(node, name)
      unless @components
        position = node[:position] || {}
        start = position[:start] || {}
        raise MissingComponentError.new(name, line: start[:line], column: start[:column])
      end

      @components.render(name, jsx_attributes(node), render_children(node), node)
    end

    def render_html_element(node, name)
      attrs = jsx_attributes(node).map { |key, value| html_attribute(key, value) }.join
      "<#{name}#{attrs}>#{render_children(node)}</#{name}>"
    end

    def html_attribute(name, value)
      case value
      when true then %( #{name}="")
      when false, nil then "" # JSX/HTML convention: a falsy prop means "omit the attribute"
      else %( #{name}="#{Renderer.escape_attr(value)}")
      end
    end

    # @return [Hash{String => Object}] attribute name -> evaluated value.
    #   Values are already evaluated where they are literals; a
    #   non-literal expression's raw source string is used as a fallback
    #   (see `LiteralExpression`).
    def jsx_attributes(node)
      (node[:attributes] || []).each_with_object({}) do |attribute, out|
        case attribute[:type]
        when "mdxJsxAttribute"
          out[attribute[:name]] = jsx_attribute_value(attribute[:value])
        when "mdxJsxExpressionAttribute"
          # Spread ({...props}): expanding it needs a bound `props` value,
          # which does not exist until the components collaborator resolves
          # imports/frontmatter bindings. Skipped rather than raised so the
          # component still
          # renders with its explicit props in the meantime.
          next
        end
      end
    end

    def jsx_attribute_value(value)
      case value
      when nil then true # bare boolean prop: <Toggle enabled />
      when String then value
      when Hash
        value[:type] == "mdxJsxAttributeValueExpression" ? LiteralExpression.evaluate(value[:value]) : value
      else
        value
      end
    end

    def render_expression(node)
      value = node[:value].to_s
      trimmed = value.strip
      return "" if trimmed.start_with?("/*") && trimmed.end_with?("*/")

      literal, matched = literal_expression(value)
      return Renderer.escape_html(stringify_expression_value(literal)) if matched

      # The `Andromeda::Components` collaborator knows how to evaluate
      # `{frontmatter.x}` and raise a clear error for anything
      # else in the static-expression subset -- it has file/line
      # context and frontmatter data this stateless renderer does not carry.
      # Without a components collaborator that understands expressions
      # (e.g. a test double that only implements `#render`), fall back to
      # a visible marker rather than raising, so plain
      # Markdown/MDX rendering still works without wiring one up.
      if @components.respond_to?(:evaluate_expression)
        position = node[:position] || {}
        start = position[:start] || {}
        evaluated = @components.evaluate_expression(value, line: start[:line], column: start[:column])
        return Renderer.escape_html(stringify_expression_value(evaluated))
      end

      "<!-- andromeda: unevaluated MDX expression: #{Renderer.escape_html(value)} -->"
    end

    # Tries the same literal grammar `LiteralExpression` uses, but reports
    # whether the whole source parsed as a literal instead of silently
    # handing back the original string on failure -- unlike
    # `LiteralExpression.evaluate` (kept as-is for attribute values, whose
    # existing callers/tests rely on "fall back to raw source" rather than
    # raising or marking).
    def literal_expression(source)
      parser = LiteralExpression::Parser.new(source)
      value = parser.parse_value
      parser.skip_ws
      parser.eof? ? [value, true] : [nil, false]
    rescue LiteralExpression::Parser::Error
      [nil, false]
    end

    def stringify_expression_value(value)
      case value
      when nil then ""
      else value.to_s
      end
    end
  end
end
