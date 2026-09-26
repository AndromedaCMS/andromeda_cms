# frozen_string_literal: true

require "test_helper"

class LoaderTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/loader", __dir__)

  # A schema-only Entry subclass, never registered via `collection` (Loader
  # only needs `entry_class.new`/`.collection_name`, not the registry), so
  # these tests can build a Loader directly without touching global state.
  class BlogPost < Andromeda::Entry
    attribute :title, :string, required: true
    attribute :pub_date, :date, required: true
    attribute :draft, :boolean, default: false
  end

  class LenientPost < Andromeda::Entry
    attribute :title, :string
  end

  def build(dir, pattern: "**/*.{md,mdx}", entry_class: BlogPost)
    Andromeda::Loader.new(
      entry_class: entry_class,
      base: File.join(FIXTURES, dir),
      pattern: pattern,
      schema: entry_class.schema
    )
  end

  # --- happy path ----------------------------------------------------------

  def test_loads_mixed_md_and_mdx_files
    entries = build("blog").load

    assert_equal 3, entries.size
    assert entries.all? { |e| e.is_a?(BlogPost) }
  end

  def test_frontmatter_is_validated_and_coerced
    entries = build("blog").load
    hello = entries.find { |e| e.id == "hello-world" }

    assert_equal "Hello World", hello.title
    assert_kind_of Date, hello.data[:pub_date]
    assert_equal false, hello.draft # default applied
  end

  def test_declared_boolean_attribute_is_coerced_from_yaml
    entries = build("blog").load
    second = entries.find { |e| e.id == "second-post" }

    assert_equal true, second.draft
  end

  def test_nested_path_becomes_a_nested_id
    entries = build("blog").load

    assert(entries.any? { |e| e.id == "nested/deep-post" })
  end

  def test_body_has_frontmatter_stripped
    entries = build("blog").load
    hello = entries.find { |e| e.id == "hello-world" }

    refute_match(/title:/, hello.body)
    assert_match(/This is the first post\./, hello.body)
  end

  def test_body_preserves_line_numbers
    entries = build("blog").load
    hello = entries.find { |e| e.id == "hello-world" }
    # The fixture has a 4-line frontmatter block (--- title pub_date ---)
    # before the body line -- it must still be on line 5, not line 2.
    assert_equal 5, hello.body.lines.length
    assert_match(/This is the first post\./, hello.body.lines.last)
  end

  def test_file_path_is_absolute
    entries = build("blog").load
    hello = entries.find { |e| e.id == "hello-world" }

    assert File.absolute_path?(hello.file_path)
    assert_equal "hello-world.md", File.basename(hello.file_path)
  end

  def test_collection_is_stamped_on_every_entry
    # A unique collection name (rather than a shared constant) so this
    # doesn't collide with any other test file's registration -- Registry
    # is process-global state shared across every test in the suite.
    klass = Class.new(BlogPost) { collection :"stamped_blog_test_#{object_id}", base: File.join(FIXTURES, "blog") }
    entries = klass.send(:entries)

    assert(entries.all? { |e| e.collection == klass.collection_name })
  end

  # --- digest --------------------------------------------------------------

  def test_digest_is_stable_for_identical_content
    Dir.mktmpdir do |dir|
      write(dir, "a.md", "---\ntitle: A\npub_date: 2022-01-01\n---\nSame body.\n")
      write(dir, "b.md", "---\ntitle: A\npub_date: 2022-01-01\n---\nSame body.\n")

      entries = build_in(dir).load
      digests = entries.map(&:digest)

      assert_equal 1, digests.uniq.size
    end
  end

  def test_digest_changes_when_content_changes
    Dir.mktmpdir do |dir|
      write(dir, "a.md", "---\ntitle: A\npub_date: 2022-01-01\n---\nOriginal body.\n")
      before = build_in(dir).load.first.digest

      write(dir, "a.md", "---\ntitle: A\npub_date: 2022-01-01\n---\nChanged body.\n")
      after = build_in(dir).load.first.digest

      refute_equal before, after
    end
  end

  # --- no frontmatter --------------------------------------------------------

  def test_file_with_no_frontmatter_loads_with_empty_data
    entries = build("no_frontmatter", entry_class: LenientPost).load

    assert_equal 1, entries.size
    entry = entries.first
    assert_nil entry.title
    assert_match(/Just a plain Markdown body/, entry.body)
  end

  # --- empty directory / no matches -----------------------------------------

  def test_empty_directory_loads_no_entries
    assert_empty build("empty").load
  end

  def test_nonexistent_directory_loads_no_entries
    assert_empty build("does_not_exist").load
  end

  def test_pattern_matching_nothing_loads_no_entries
    assert_empty build("blog", pattern: "**/*.rst").load
  end

  # --- validation errors, collected across files ----------------------------

  def test_invalid_frontmatter_across_multiple_files_is_reported_together
    error = assert_raises(Andromeda::LoaderError) { build("invalid").load }

    assert_match(/missing_title\.md.*title is required/m, error.message)
    assert_match(/bad_type\.md.*title.*not a string/m, error.message)
  end

  def test_loader_error_exposes_individual_messages
    error = assert_raises(Andromeda::LoaderError) { build("invalid").load }

    assert_equal 2, error.messages.size
  end

  def test_missing_required_attribute_is_reported_with_the_file_path
    error = assert_raises(Andromeda::LoaderError) { build("invalid").load }

    assert(error.messages.any? { |m| m.include?("missing_title.md") && m.include?("title is required") })
  end

  # --- duplicate ids ---------------------------------------------------------

  def test_duplicate_ids_raise_loader_error
    error = assert_raises(Andromeda::LoaderError) { build("duplicates").load }

    assert_match(/duplicate id "hello-world"/, error.message)
  end

  private

  def build_in(dir, entry_class: BlogPost)
    Andromeda::Loader.new(entry_class: entry_class, base: dir, pattern: "**/*.md", schema: entry_class.schema)
  end

  def write(dir, name, content)
    File.write(File.join(dir, name), content)
  end
end
