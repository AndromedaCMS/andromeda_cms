# frozen_string_literal: true

require "test_helper"

class HelpersTest < Minitest::Test
  def setup
    Content::Post.reload!
    @view = ActionView::Base.empty
  end

  def test_content_resolves_asset_markers_and_is_html_safe
    html = @view.andromeda_content(Content::Post.find("with-image"))

    assert_predicate html, :html_safe?
    refute_includes html, Andromeda::Assets::MARKER
  end

  def test_content_is_wrapped_in_andromeda_content_tag
    html = @view.andromeda_content(Content::Post.find("with-image"))

    assert_match %r{\A<andromeda-content>.*</andromeda-content>\z}m, html
  end

  def test_toc_nests_by_heading_depth
    entry = stub_entry([
                         { depth: 2, slug: "one", text: "One" },
                         { depth: 3, slug: "one-a", text: "One A" },
                         { depth: 2, slug: "two", text: "Two" }
                       ])

    toc = @view.andromeda_toc(entry)

    assert_includes toc, %(<a href="#one">One</a>)
    assert_includes toc, %(<a href="#one-a">One A</a>)
    assert_match %r{<li><a href="#one">One</a><ul>.*One A.*</ul></li>}m, toc
  end

  def test_toc_respects_min_and_max
    entry = stub_entry([
                         { depth: 1, slug: "title", text: "Title" },
                         { depth: 2, slug: "section", text: "Section" },
                         { depth: 4, slug: "deep", text: "Deep" }
                       ])

    toc = @view.andromeda_toc(entry, min: 2, max: 3)

    refute_includes toc, "Title"
    refute_includes toc, "Deep"
    assert_includes toc, "Section"
  end

  def test_toc_is_empty_when_nothing_matches
    assert_equal "", @view.andromeda_toc(stub_entry([]))
  end

  def test_toc_accepts_string_keyed_headings_from_the_store
    entry = stub_entry([{ "depth" => 2, "slug" => "one", "text" => "One" }])

    assert_includes @view.andromeda_toc(entry), %(href="#one")
  end

  def test_meta_tags_emit_only_what_the_entry_has
    entry = Content::Post.find("hello-world")

    tags = @view.andromeda_meta_tags(entry, url: "https://example.com/blog/hello-world")

    assert_includes tags, "<title>Hello world</title>"
    assert_includes tags, %(rel="canonical")
    refute_includes tags, "description"
  end

  def test_image_url_resolves_and_tolerates_nil
    entry = Content::Post.find("with-hero")

    assert_match %r{^/assets/andromeda/blog/with-hero/hero}, @view.andromeda_image_url(entry.hero_image)
    assert_nil @view.andromeda_image_url(nil)
  end

  def test_image_url_is_a_marker_while_converting
    entry = Content::Post.find("with-hero")

    url = Andromeda::BuildContext.converting("blog/test") { @view.andromeda_image_url(entry.hero_image) }

    assert_equal "#{Andromeda::Assets::MARKER}andromeda/blog/with-hero/hero.png", url
  end

  def test_image_tag_passes_the_marker_through_while_converting
    entry = Content::Post.find("with-hero")

    html = Andromeda::BuildContext.converting("blog/test") do
      @view.image_tag(@view.andromeda_image_url(entry.hero_image), alt: "")
    end

    assert_includes html, %(src="#{Andromeda::Assets::MARKER}andromeda/blog/with-hero/hero.png")
  end

  private

  def stub_entry(headings)
    Struct.new(:headings, :data, :html).new(headings, {}, "")
  end
end
