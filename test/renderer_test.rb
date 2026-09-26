# frozen_string_literal: true

require "test_helper"

class RendererTest < Minitest::Test
  def render(source, mdx: false, **opts)
    tree = Andromeda::Parser.parse(source, mdx: mdx)
    Andromeda::Renderer.new(**opts).render(tree)
  end

  def html(source, mdx: false, **opts)
    render(source, mdx: mdx, **opts).html
  end

  # --- basic block/inline nodes ------------------------------------------

  def test_paragraph_and_text
    assert_equal "<p>Hello world</p>\n", html("Hello world")
  end

  def test_emphasis_strong_delete_inline_code
    out = html("*em* **strong** ~~gone~~ `code`")
    assert_includes out, "<em>em</em>"
    assert_includes out, "<strong>strong</strong>"
    assert_includes out, "<del>gone</del>"
    assert_includes out, "<code>code</code>"
  end

  def test_thematic_break
    out = html("above\n\n---\n\nbelow")
    assert_includes out, "<hr />"
  end

  def test_hard_line_break
    out = html("line one  \nline two")
    assert_includes out, "line one<br />"
  end

  def test_blockquote_nesting
    out = html("> quoted **text**")
    assert_includes out, "<blockquote>"
    assert_includes out, "<strong>text</strong>"
  end

  # --- escaping ------------------------------------------------------------

  def test_text_is_html_escaped
    out = html("Tom & Jerry < 5 > 3")
    assert_includes out, "Tom &amp; Jerry &lt; 5 &gt; 3"
  end

  def test_link_url_and_title_are_attribute_escaped
    out = html('[a](https://example.com/?a=1&b=2 "a \"quoted\" title")')
    assert_includes out, 'href="https://example.com/?a=1&amp;b=2"'
    assert_includes out, "title=\"a &quot;quoted&quot; title\""
  end

  def test_image_alt_is_attribute_escaped
    # Straight quotes become curly quotes first (smart punctuation, enabled
    # by default -- see test_smart_punctuation_is_enabled_by_default below),
    # so there is no literal `"` left needing `&quot;`; `&` still does.
    out = html('![alt "text" & more](/img.png)')
    assert_includes out, "alt=\"alt “text” &amp; more\""
  end

  def test_raw_html_is_passed_through_unescaped
    out = html("before <span class=\"x\">raw</span> after")
    assert_includes out, '<span class="x">raw</span>'
  end

  def test_no_double_escaping_of_entities_already_in_source
    # CommonMark resolves character references in text *during parsing*, so
    # by the time Renderer sees this text node its value is already the
    # plain "&" -- Renderer's own escaping is the only pass that ever
    # touches it, producing "&amp;" rather than "&amp;amp;".
    out = html("Tom &amp; Jerry")
    assert_includes out, "Tom &amp; Jerry"
    refute_includes out, "&amp;amp;"
  end

  # --- links / images / references -----------------------------------------

  def test_link_and_image
    out = html('[text](https://example.com) and ![alt](/img.png "t")')
    assert_includes out, '<a href="https://example.com">text</a>'
    assert_includes out, '<img src="/img.png" alt="alt" title="t" />'
  end

  def test_link_resolver_rewrites_url
    out = html("[x](./other.md)", link_resolver: ->(url, _node) { url.sub(/\.md\z/, ".html") })
    assert_includes out, 'href="./other.html"'
  end

  def test_image_resolver_rewrites_url
    out = html("![x](./cover.png)", image_resolver: ->(url, _node) { "/assets/#{File.basename(url)}" })
    assert_includes out, 'src="/assets/cover.png"'
  end

  def test_reference_style_link_resolves_via_definition
    out = html("[text][ref]\n\n[ref]: https://example.com \"Title\"")
    assert_includes out, '<a href="https://example.com" title="Title">text</a>'
  end

  def test_image_reference_resolves_via_definition
    out = html("![alt][ref]\n\n[ref]: /img.png")
    assert_includes out, '<img src="/img.png" alt="alt" />'
  end

  def test_definition_itself_renders_nothing_visible
    out = html("[ref]: https://example.com")
    refute_includes out, "https://example.com"
  end

  def test_dangling_link_reference_falls_back_to_plain_children
    out = html("[text][missing]")
    assert_includes out, "text"
    refute_includes out, "<a "
  end

  def test_dangling_image_reference_renders_nothing
    out = html("![alt][missing]")
    refute_includes out, "<img"
  end

  # --- lists -----------------------------------------------------------------

  def test_unordered_list
    out = html("- one\n- two\n")
    assert_includes out, "<ul>"
    assert_includes out, "<li>one</li>"
    assert_includes out, "<li>two</li>"
  end

  def test_ordered_list_with_custom_start
    out = html("5. five\n6. six\n")
    assert_includes out, '<ol start="5">'
  end

  def test_ordered_list_starting_at_one_has_no_start_attribute
    out = html("1. one\n2. two\n")
    assert_includes out, "<ol>"
    refute_includes out, "start="
  end

  def test_tight_list_does_not_wrap_items_in_paragraphs
    out = html("- one\n- two\n")
    refute_includes out, "<p>"
  end

  def test_loose_list_wraps_items_in_paragraphs
    out = html("- one\n\n- two\n")
    assert_includes out, "<li><p>one</p>\n</li>"
  end

  def test_task_list_items_render_disabled_checkboxes
    out = html("- [ ] todo\n- [x] done\n")
    assert_includes out, '<input type="checkbox" disabled="" />'
    assert_includes out, '<input type="checkbox" disabled="" checked="" />'
    assert_includes out, 'class="task-list-item"'
  end

  def test_plain_list_item_has_no_checkbox
    out = html("- not a task\n")
    refute_includes out, "checkbox"
  end

  def test_nested_list
    out = html("- one\n  - nested\n- two\n")
    assert_includes out, "<ul>\n<li>one<ul>\n<li>nested</li>\n</ul>\n</li>\n<li>two</li>\n</ul>\n"
  end

  # --- tables ------------------------------------------------------------

  def test_table_with_each_alignment
    src = "| A | B | C | D |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |\n"
    out = html(src)

    assert_includes out, '<th style="text-align:left">A</th>'
    assert_includes out, '<th style="text-align:center">B</th>'
    assert_includes out, '<th style="text-align:right">C</th>'
    assert_includes out, "<th>D</th>"
    assert_includes out, "<thead>"
    assert_includes out, "<tbody>"
    assert_includes out, '<td style="text-align:left">1</td>'
  end

  # --- code blocks ---------------------------------------------------------

  def test_code_block_with_known_language_is_highlighted
    out = html("```ruby\nputs 1\n```")
    assert_includes out, 'class="astro-code github-dark"'
    assert_includes out, 'data-language="ruby"'
    assert_includes out, "<span style=" # Rouge emitted at least one styled span
  end

  def test_code_block_without_language_is_plain_but_valid
    out = html("```\nplain text\n```")
    assert_includes out, "<pre class=\"astro-code github-dark\""
    assert_includes out, "plain text"
    refute_includes out, "data-language="
  end

  def test_code_block_with_unknown_language_does_not_raise
    out = html("```not-a-real-language\nsome text\n```")
    assert_includes out, 'data-language="not-a-real-language"'
    assert_includes out, "some text"
  end

  def test_code_block_content_is_escaped_when_unhighlighted
    out = html("```\n<script>alert(1)</script>\n```")
    assert_includes out, "&lt;script&gt;"
    refute_includes out, "<script>"
  end

  def test_inline_code_is_escaped
    out = html("`<b>`")
    assert_includes out, "<code>&lt;b&gt;</code>"
  end

  # --- footnotes -----------------------------------------------------------

  def test_single_footnote
    out = html("A note.[^1]\n\n[^1]: The body.\n")

    assert_includes out, 'href="#user-content-fn-1"'
    assert_includes out, 'id="user-content-fnref-1"'
    assert_includes out, '<section data-footnotes="" class="footnotes">'
    assert_includes out, '<li id="user-content-fn-1">'
    assert_includes out, "The body."
    assert_includes out, 'href="#user-content-fnref-1"'
  end

  def test_multiple_footnotes_are_numbered_in_order_of_first_reference
    src = "First.[^b]\n\nSecond.[^a]\n\n[^a]: A body.\n[^b]: B body.\n"
    out = html(src)

    fn_b_index = out[/user-content-fnref-b"[^>]*>(\d+)</, 1]
    fn_a_index = out[/user-content-fnref-a"[^>]*>(\d+)</, 1]

    assert_equal "1", fn_b_index
    assert_equal "2", fn_a_index
  end

  def test_repeated_reference_to_the_same_footnote_gets_distinct_backrefs
    src = "One.[^x] Two.[^x]\n\n[^x]: Shared.\n"
    out = html(src)

    assert_includes out, 'id="user-content-fnref-x"'
    assert_includes out, 'id="user-content-fnref-x-2"'
    assert_includes out, 'href="#user-content-fnref-x"'
    assert_includes out, 'href="#user-content-fnref-x-2"'
  end

  # --- math ------------------------------------------------------------------

  def test_inline_math
    out = html('$e=mc^2$')
    assert_includes out, '<span class="math math-inline">e=mc^2</span>'
  end

  def test_block_math
    out = html("$$\nx^2\n$$")
    assert_includes out, '<div class="math math-display">x^2</div>'
  end

  # --- smart punctuation -----------------------------------------------------

  def test_smart_punctuation_is_enabled_by_default
    # Astro enables remark-smartypants unconditionally; confirmed
    # that satteri-pulldown-cmark's
    # DEFAULT_OPTIONS does *not* include ENABLE_SMART_PUNCTUATION, so
    # ext/andromeda_cms/src/lib.rs turns it on explicitly. This test would
    # fail if that were ever reverted.
    out = html(%(She said "hello" -- it's fine... really))

    assert_includes out, "“hello”"
    assert_includes out, "–"
    assert_includes out, "it’s"
    assert_includes out, "…"
  end

  # --- frontmatter assumption ------------------------------------------------

  def test_yaml_node_raises_if_it_somehow_reaches_the_renderer
    tree = Andromeda::Parser.parse("---\ntitle: Hello\n---\n\nBody\n")

    assert_raises(Andromeda::Renderer::UnexpectedFrontmatterNodeError) do
      Andromeda::Renderer.new.render(tree)
    end
  end

  # --- headings --------------------------------------------------------------

  def test_heading_gets_an_id_from_the_slugger
    out = html("## Getting Started")
    assert_includes out, '<h2 id="getting-started">Getting Started</h2>'
  end

  def test_headings_are_collected_with_depth_slug_and_text
    result = render("# One\n\n## Two\n")

    assert_equal(
      [{ depth: 1, slug: "one", text: "One" }, { depth: 2, slug: "two", text: "Two" }],
      result.headings
    )
  end

  def test_duplicate_headings_collect_distinct_slugs
    result = render("# Intro\n\n# Intro\n")

    assert_equal %w[intro intro-1], result.headings.map { |h| h[:slug] }
  end

  def test_heading_text_excludes_raw_html_tag_markup_but_keeps_surrounding_text
    # "<b>"/"</b>" are their own `html` leaf nodes and contribute nothing;
    # "World" between them is a separate `text` node and does count, along
    # with the emphasis's own nested text -- only the tag markup itself is
    # excluded, not text that happens to sit between two raw tags.
    result = render("# Hello <b>World</b> *there*")

    assert_equal "Hello World there", result.headings.first[:text]
  end

  def test_headings_match_the_ids_actually_emitted_in_the_html
    result = render("# First\n\n# First\n\n## Second\n")

    result.headings.each do |heading|
      assert_includes result.html, "id=\"#{heading[:slug]}\""
    end
  end

  # --- MDX: components -------------------------------------------------------

  class RecordingComponents
    Call = Struct.new(:name, :attrs, :children_html, :node, keyword_init: false)
    attr_reader :calls

    def initialize
      @calls = []
    end

    def render(name, attrs, children_html, node)
      @calls << Call.new(name, attrs, children_html, node)
      "<stub name=\"#{name}\">#{children_html}</stub>"
    end
  end

  def test_component_delegation_receives_name_attributes_and_children_html
    components = RecordingComponents.new
    out = html('<Badge text="new" count={3} />**bold**</Badge>'.sub("</Badge>", ""), mdx: true, components: components)
    call = components.calls.first

    assert_equal "Badge", call.name
    assert_equal({ "text" => "new", "count" => 3 }, call.attrs)
    assert_includes out, '<stub name="Badge">'
  end

  def test_component_with_markdown_children_renders_nested_markdown_first
    components = RecordingComponents.new
    html("<Card>**bold** and a [link](/x)</Card>", mdx: true, components: components)
    call = components.calls.first

    assert_equal "<strong>bold</strong> and a <a href=\"/x\">link</a>", call.children_html
  end

  def test_nested_components_both_get_delegated
    components = RecordingComponents.new
    html("<Outer><Inner>deep</Inner></Outer>", mdx: true, components: components)

    assert_equal %w[Inner Outer], components.calls.map(&:name).sort
  end

  def test_boolean_prop_evaluates_to_true
    components = RecordingComponents.new
    html("<Toggle enabled />", mdx: true, components: components)

    assert_equal({ "enabled" => true }, components.calls.first.attrs)
  end

  def test_non_literal_expression_prop_falls_back_to_raw_source
    components = RecordingComponents.new
    html("<Counter count={1 + 1} />", mdx: true, components: components)

    assert_equal "1 + 1", components.calls.first.attrs["count"]
  end

  def test_array_and_object_literal_props_are_evaluated
    components = RecordingComponents.new
    html('<Widget items={["a", "b"]} meta={{a: 1, b: true}} />', mdx: true, components: components)
    attrs = components.calls.first.attrs

    assert_equal %w[a b], attrs["items"]
    assert_equal({ "a" => 1, "b" => true }, attrs["meta"])
  end

  def test_lowercase_tag_renders_as_plain_html_not_a_component
    components = RecordingComponents.new
    out = html('<div class="wrap">hi</div>', mdx: true, components: components)

    assert_empty components.calls
    assert_includes out, '<div class="wrap">hi</div>'
  end

  def test_member_expression_tag_name_is_treated_as_a_component
    components = RecordingComponents.new
    html("<Tabs.Item>x</Tabs.Item>", mdx: true, components: components)

    assert_equal "Tabs.Item", components.calls.first.name
  end

  def test_missing_component_collaborator_raises_naming_tag_and_line
    tree = Andromeda::Parser.parse("intro\n\n<Foo />\n", mdx: true)

    error = assert_raises(Andromeda::Renderer::MissingComponentError) do
      Andromeda::Renderer.new.render(tree)
    end

    assert_equal "Foo", error.tag_name
    assert_equal 3, error.line
  end

  def test_fragment_renders_only_its_children
    out = html("<>fragment text</>", mdx: true)
    assert_includes out, "fragment text"
  end

  # --- MDX: expressions --------------------------------------------------

  def test_comment_only_expression_is_dropped
    out = html("before\n\n{/* just a comment */}\n\nafter", mdx: true)

    refute_includes out, "comment"
    assert_includes out, "before"
    assert_includes out, "after"
  end

  def test_non_comment_expression_is_left_as_a_visible_marker_not_raised
    # Current behaviour: real expression evaluation is handled
    # elsewhere; this test pins today's fallback so a future
    # change to it is a deliberate decision.
    out = html("{1 + 1}", mdx: true)

    assert_includes out, "andromeda: unevaluated MDX expression"
    assert_includes out, "1 + 1"
  end

  def test_esm_import_is_not_rendered
    out = html("import Foo from \"./foo.astro\"\n\nbody", mdx: true)

    refute_includes out, "import Foo"
    assert_includes out, "body"
  end
end
