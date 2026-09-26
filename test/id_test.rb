# frozen_string_literal: true

require "test_helper"

class IdTest < Minitest::Test
  # --- path-derived ids --------------------------------------------------

  def test_simple_filename
    assert_equal "hello-world", Andromeda::Id.generate("hello-world.md")
  end

  def test_nested_path_slugs_each_segment
    assert_equal "guides/getting-started", Andromeda::Id.generate("Guides/Getting Started.md")
  end

  def test_deeply_nested_path
    assert_equal "a/b/c", Andromeda::Id.generate("A/B/C.mdx")
  end

  def test_trailing_index_is_dropped
    assert_equal "posts/hello", Andromeda::Id.generate("posts/hello/index.mdx")
  end

  def test_trailing_index_case_insensitive
    assert_equal "posts/hello", Andromeda::Id.generate("posts/hello/Index.md")
  end

  # Astro's rule only strips `/index`, so a collection's own index file keeps
  # the id "index" rather than collapsing to an empty string.
  def test_lone_index_at_root_keeps_its_name
    assert_equal "index", Andromeda::Id.generate("index.md")
  end

  def test_uppercase_and_spaces_are_slugified
    assert_equal "my-great-post", Andromeda::Id.generate("My Great Post.md")
  end

  def test_date_prefix_is_kept_verbatim_no_special_casing
    assert_equal "blog/2026-09-01-hello-world", Andromeda::Id.generate("blog/2026-09-01-hello-world.md")
  end

  def test_japanese_filename_is_kept_as_is
    assert_equal "日本語の記事", Andromeda::Id.generate("日本語の記事.md")
  end

  # Only the last extension is stripped from the path before slugging --
  # the remaining "archive.tar" segment is then run through github-slugger
  # like any other segment, which strips the (now mid-segment) period along
  # with every other punctuation character.
  def test_extension_stripping_only_removes_the_last_extension
    assert_equal "archivetar", Andromeda::Id.generate("archive.tar.md")
  end

  def test_mdx_extension
    assert_equal "hello", Andromeda::Id.generate("hello.mdx")
  end

  # --- frontmatter `slug` override ----------------------------------------

  def test_frontmatter_slug_wins_verbatim_over_path
    assert_equal "custom-id", Andromeda::Id.generate("some/nested/path.md", slug: "custom-id")
  end

  def test_frontmatter_slug_that_is_not_slug_shaped_is_used_verbatim
    assert_equal "Not A Slug At All!", Andromeda::Id.generate("whatever.md", slug: "Not A Slug At All!")
  end

  def test_frontmatter_slug_is_stringified
    assert_equal "42", Andromeda::Id.generate("whatever.md", slug: 42)
  end

  def test_explicit_nil_slug_falls_back_to_path_rule
    assert_equal "hello-world", Andromeda::Id.generate("hello-world.md", slug: nil)
  end

  # Astro checks `if (data.slug)`, so every JavaScript-falsy value falls back.
  def test_falsy_slugs_fall_back_to_path_rule_like_astro
    ["", false, 0, 0.0, Float::NAN].each do |slug|
      assert_equal "hello-world", Andromeda::Id.generate("hello-world.md", slug: slug), "slug: #{slug.inspect}"
    end
  end

  def test_truthy_non_string_slugs_are_stringified
    assert_equal "true", Andromeda::Id.generate("whatever.md", slug: true)
    assert_equal "-1", Andromeda::Id.generate("whatever.md", slug: -1)
  end
end
