# frozen_string_literal: true

require "test_helper"

# Boots the dummy Rails app so `Andromeda::Components` can fall back to its
# real default (`ApplicationController.renderer`) instead of a stub.
# Guarded rather than a bare `require` because another test file in the same
# Rake::TestTask run may boot it first -- `Rails.application.initialize!`
# raises if called twice, but checking `Rails.application` first is safe
# regardless of which test file gets there.
require File.expand_path("dummy/config/environment", __dir__) unless defined?(Rails) && Rails.application

class ComponentsTest < Minitest::Test
  def setup
    Andromeda::Components.clear_registrations!
  end

  def teardown
    Andromeda::Components.clear_registrations!
  end

  def render_mdx(source, path: "app/content/blog/test.mdx", frontmatter: {})
    tree = Andromeda::Parser.parse(source, mdx: true)
    components = Andromeda::Components.new(tree: tree, path: path, frontmatter: frontmatter)
    Andromeda::Renderer.new(components: components).render(tree).html
  end

  # --- resolution: convention -------------------------------------------

  def test_resolves_by_naming_convention_without_any_import
    out = render_mdx('<PrecedenceWidget />')
    assert_includes out, "CONVENTION-WINS"
  end

  def test_camel_case_tag_name_is_underscored_for_the_convention_lookup
    out = render_mdx("<Card>hi</Card>")
    assert_includes out, '<div class="card">'
  end

  # --- resolution: import path --------------------------------------------

  def test_resolves_by_import_path_when_path_points_at_an_existing_partial
    out = render_mdx(<<~MDX)
      import PrecedenceWidget from 'content_components/precedence_import'

      <PrecedenceWidget />
    MDX

    assert_includes out, "IMPORT-WINS"
  end

  def test_import_path_that_does_not_resolve_falls_back_to_convention
    out = render_mdx(<<~MDX)
      import PrecedenceWidget from 'content_components/does_not_exist'

      <PrecedenceWidget />
    MDX

    assert_includes out, "CONVENTION-WINS"
  end

  def test_named_import_with_as_rename_resolves_by_the_local_name
    out = render_mdx(<<~MDX)
      import { PrecedenceWidget as Renamed } from 'content_components/precedence_import'

      <Renamed />
    MDX

    assert_includes out, "IMPORT-WINS"
  end

  def test_named_import_without_rename_resolves_too
    out = render_mdx(<<~MDX)
      import { PrecedenceWidget } from 'content_components/precedence_import'

      <PrecedenceWidget />
    MDX

    assert_includes out, "IMPORT-WINS"
  end

  # --- resolution: explicit registration + precedence ---------------------

  def test_explicit_registration_wins_over_import_and_convention
    Andromeda::Components.register(:PrecedenceWidget, "content_components/precedence_registered")

    out = render_mdx(<<~MDX)
      import PrecedenceWidget from 'content_components/precedence_import'

      <PrecedenceWidget />
    MDX

    assert_includes out, "REGISTERED-WINS"
  end

  def test_import_path_wins_over_convention_when_both_resolve
    out = render_mdx(<<~MDX)
      import PrecedenceWidget from 'content_components/precedence_import'

      <PrecedenceWidget />
    MDX

    assert_includes out, "IMPORT-WINS"
    refute_includes out, "CONVENTION-WINS"
  end

  # --- props ----------------------------------------------------------------

  def test_string_prop
    out = render_mdx('<Badge label="new" />')
    assert_includes out, ">new</span>"
  end

  def test_integer_literal_prop
    out = render_mdx("<Badge count={7} />")
    assert_includes out, 'data-count="7"'
  end

  def test_boolean_literal_prop
    out = render_mdx("<Toggle enabled={true} />")
    assert_includes out, "ON"
  end

  def test_bare_boolean_prop_defaults_to_true
    out = render_mdx("<Toggle enabled />")
    assert_includes out, "ON"
  end

  def test_array_and_object_literal_props
    out = render_mdx('<Widget items={["a", "b"]} meta={{a: 1, done: true}} />')
    assert_includes out, 'data-items="a,b"'
    assert_includes out, "a&quot; =&gt; 1"
    assert_includes out, "done&quot; =&gt; true"
  end

  def test_camel_case_prop_name_is_converted_to_snake_case
    out = render_mdx('<LinkButton linkText="Read more" />')
    assert_includes out, ">Read more<"
  end

  def test_non_literal_expression_prop_raises_naming_file_and_line
    error = assert_raises(Andromeda::Components::UnsupportedExpressionError) do
      render_mdx("line one\n\n<Badge count={1 + 1} />\n", path: "app/content/blog/x.mdx")
    end

    assert_equal "1 + 1", error.source
    assert_equal "app/content/blog/x.mdx", error.path
    assert_equal 3, error.line
    assert_includes error.message, "app/content/blog/x.mdx:3"
  end

  def test_missing_optional_prop_uses_partial_local_assigns_default
    out = render_mdx("<Badge />")
    assert_includes out, ">default</span>"
  end

  # --- children / content ----------------------------------------------------

  def test_markdown_children_are_rendered_to_html_and_passed_as_content
    out = render_mdx("<Card>**bold** and a [link](/x)</Card>")
    assert_includes out, '<div class="card"><strong>bold</strong> and a <a href="/x">link</a></div>'
  end

  def test_nested_components_both_resolve_and_render
    out = render_mdx("<Outer><Inner>deep</Inner></Outer>")
    assert_includes out, '<div class="outer"><span class="inner">deep</span>'
    assert_includes out, "</div>"
  end

  def test_inline_component_inside_a_paragraph
    out = render_mdx("Some text with an <Note>inline note</Note> in the middle.")
    assert_includes out, "<mark>inline note</mark>"
    assert_includes out, "<p>Some text with an"
  end

  # --- slots ------------------------------------------------------------------

  def test_fragment_slot_and_remaining_content
    out = render_mdx(<<~MDX)
      <Panel>
        <Fragment slot="header">Title</Fragment>

        body text

        <Fragment slot="footer">Bye</Fragment>
      </Panel>
    MDX

    assert_includes out, "<header>Title</header>"
    assert_includes out, "<footer>Bye</footer>"
    assert_includes out, "body text"
  end

  def test_element_slot_with_slot_attribute
    out = render_mdx(<<~MDX)
      <Panel>
        <div slot="header">Element slot</div>

        remaining
      </Panel>
    MDX

    assert_includes out, "<header>Element slot</header>"
    assert_includes out, "remaining"
    # the wrapper `div` itself is not rendered -- `slot` is routing only.
    refute_includes out, "<div slot"
  end

  def test_several_named_slots_do_not_bleed_into_each_other
    out = render_mdx(<<~MDX)
      <Panel>
        <Fragment slot="header">H</Fragment>

        <Fragment slot="footer">F</Fragment>

        middle
      </Panel>
    MDX

    assert_includes out, "<header>H</header>"
    assert_includes out, "<footer>F</footer>"
    assert_includes out, "middle"
  end

  # --- errors -------------------------------------------------------------

  def test_missing_partial_error_names_tag_file_line_and_expected_path
    error = assert_raises(Andromeda::Components::MissingPartialError) do
      render_mdx("intro\n\n<GhostComponent />\n", path: "app/content/blog/ghost.mdx")
    end

    assert_equal "GhostComponent", error.tag_name
    assert_equal "app/content/blog/ghost.mdx", error.path
    assert_equal 3, error.line
    assert_equal "app/views/content_components/_ghost_component.html.erb", error.expected_path
    assert_includes error.message, "app/content/blog/ghost.mdx:3"
    assert_includes error.message, "app/views/content_components/_ghost_component.html.erb"
    assert_includes error.message, "rails g andromeda:component GhostComponent"
  end

  def test_member_expression_tag_name_raises_a_clear_error
    error = assert_raises(Andromeda::Components::InvalidComponentNameError) do
      render_mdx("<Tabs.Item>x</Tabs.Item>")
    end

    assert_equal "Tabs.Item", error.tag_name
  end

  def test_member_expression_tag_can_still_be_resolved_by_explicit_registration
    Andromeda::Components.register("Tabs.Item", "content_components/card")

    out = render_mdx("<Tabs.Item>x</Tabs.Item>")
    assert_includes out, '<div class="card">x</div>'
  end

  def test_no_renderer_available_outside_rails_raises_a_clear_error
    tree = Andromeda::Parser.parse("<Badge />", mdx: true)
    components = Class.new(Andromeda::Components) do
      def default_view
        nil
      end
    end.new(tree: tree, path: "app/content/blog/x.mdx")

    error = assert_raises(Andromeda::Components::NoRendererAvailableError) do
      Andromeda::Renderer.new(components: components).render(tree)
    end

    assert_includes error.message, "app/content/blog/x.mdx"
  end

  # --- frontmatter / static expressions ------------------------------------

  def test_frontmatter_prop_resolves
    out = render_mdx('<Greeting title={frontmatter.title} />', frontmatter: { title: "Hello" })
    assert_includes out, "<h1 class=\"greeting\">Hello</h1>"
  end

  def test_frontmatter_flow_expression_resolves
    out = render_mdx("Post: {frontmatter.title}", frontmatter: { title: "Hello" })
    assert_includes out, "Post: Hello"
  end

  def test_missing_frontmatter_key_resolves_to_empty
    out = render_mdx("Post: {frontmatter.missing}", frontmatter: { title: "Hello" })
    assert_includes out, "Post: "
  end

  def test_unsupported_flow_expression_raises_with_components_present
    error = assert_raises(Andromeda::Components::UnsupportedExpressionError) do
      render_mdx("line\n\n{doSomething()}\n")
    end

    assert_includes error.message, "doSomething()"
  end

  def test_mdx_comment_expression_is_still_dropped
    out = render_mdx("before\n\n{/* a comment */}\n\nafter")
    refute_includes out, "comment"
    assert_includes out, "before"
    assert_includes out, "after"
  end

  # --- Rails integration: ApplicationController.renderer, no annotation leak --

  def test_renders_through_application_controller_renderer_by_default
    tree = Andromeda::Parser.parse("<Card>hi</Card>", mdx: true)
    components = Andromeda::Components.new(tree: tree, path: "app/content/blog/x.mdx")

    assert_kind_of ActionController::Renderer, components.instance_variable_get(:@view)
    out = Andromeda::Renderer.new(components: components).render(tree).html
    assert_includes out, '<div class="card">hi</div>'
  end

  def test_no_template_annotation_comments_leak_into_rendered_output
    previous = ActionView::Base.annotate_rendered_view_with_filenames
    ActionView::Base.annotate_rendered_view_with_filenames = true
    begin
      out = render_mdx("<Card>hi</Card>")
      refute_includes out, "BEGIN"
      refute_includes out, "<!-- "
    ensure
      ActionView::Base.annotate_rendered_view_with_filenames = previous
    end
  end

  # --- resolution: import paths stay inside app/views -----------------------

  # ActionView would refuse to render it anyway; the existence check must not
  # look outside app/views either, or error messages reveal which files exist.
  def test_import_path_escaping_app_views_is_not_considered_even_if_the_file_exists
    outside = Rails.root.join("config/_precedence_probe.html.erb")
    File.write(outside, "OUTSIDE")

    out = render_mdx(<<~MDX)
      import PrecedenceWidget from '../../config/precedence_probe'

      <PrecedenceWidget />
    MDX

    assert_includes out, "CONVENTION-WINS"
    refute_includes out, "OUTSIDE"
  ensure
    FileUtils.rm_f(outside)
  end
end
