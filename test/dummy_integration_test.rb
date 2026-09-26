# frozen_string_literal: true

require "test_helper"
require "rack/test"

# Exercises the whole stack the way an application does: a real request
# through routing, a controller, the layout and the view helpers.
class DummyIntegrationTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def setup
    @mode = Andromeda.config.mode
    Andromeda.config.mode = :development
    Content::Post.reload!
  end

  def teardown
    Andromeda.config.mode = @mode
    FileUtils.rm_rf(Rails.root.join(Andromeda.config.build_path))
  end

  def test_index_lists_published_entries_only
    get "/blog"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Hello world"
    refute_includes last_response.body, "Second post", "draft: true must be filtered by the published scope"
  end

  def test_show_renders_converted_content_inside_the_layout
    get "/blog/hello-world"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "<html>", "the app layout still wraps the page"
    assert_includes last_response.body, %(<h2 id="getting-started">Getting started</h2>)
    assert_includes last_response.body, "astro-code"
  end

  def test_mdx_entry_expands_components_through_a_partial
    get "/blog/second-post"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "callout--tip"
    assert_includes last_response.body, "<strong>inside</strong>"
    refute_includes last_response.body, "BEGIN app/views", "template annotations must not leak into content"
  end

  def test_edits_are_picked_up_without_a_build_step
    path = Rails.root.join("app/content/blog/hello-world.md")
    original = File.read(path)

    File.write(path, original.sub("The first post", "An edited post"))
    Content::Post.reload!
    get "/blog/hello-world"

    assert_includes last_response.body, "An edited post"
  ensure
    File.write(path, original)
    Content::Post.reload!
  end

  def test_an_unknown_slug_is_a_404_not_a_500
    get "/blog/does-not-exist"

    assert_equal 404, last_response.status
  end
end
