# frozen_string_literal: true

require "test_helper"
require "date"

class EntryTest < Minitest::Test
  # Not registered via `collection` -- these tests build instances directly,
  # so there is no Loader/registry involvement to isolate between tests.
  class Post < Andromeda::Entry
    attribute :title, :string, required: true
    attribute :pub_date, :date
  end

  def build(id: "hello-world", data: { title: "Hello", pub_date: Date.new(2022, 7, 8) }, body: "Body text.\n")
    Post.new(id: id, collection: :blog, data: data, body: body, file_path: "/tmp/hello-world.md", digest: "abc123")
  end

  # --- instance data access ------------------------------------------------

  def test_reads_id_collection_body_file_path_digest
    entry = build

    assert_equal "hello-world", entry.id
    assert_equal :blog, entry.collection
    assert_equal "Body text.\n", entry.body
    assert_equal "/tmp/hello-world.md", entry.file_path
    assert_equal "abc123", entry.digest
  end

  def test_data_is_symbol_keyed
    entry = build

    assert_equal "Hello", entry.data[:title]
  end

  # --- attribute readers ----------------------------------------------------

  def test_declared_attribute_reader_delegates_to_data
    entry = build

    assert_equal "Hello", entry.title
    assert_equal Date.new(2022, 7, 8), entry.pub_date
  end

  def test_undeclared_attribute_raises_no_method_error
    entry = build

    assert_raises(NoMethodError) { entry.this_was_never_declared }
  end

  # --- to_h / from_h round-trip ---------------------------------------------

  def test_to_h_contains_every_persisted_field
    entry = build
    hash = entry.to_h

    assert_equal(
      { id: "hello-world", collection: :blog, data: { title: "Hello", pub_date: Date.new(2022, 7, 8) },
        body: "Body text.\n", file_path: "/tmp/hello-world.md", digest: "abc123" },
      hash
    )
  end

  def test_from_h_round_trips_without_reparsing
    entry = build
    rebuilt = Post.from_h(entry.to_h)

    assert_equal entry.to_h, rebuilt.to_h
    assert_equal entry.title, rebuilt.title
    assert_kind_of Post, rebuilt
  end

  def test_from_h_accepts_string_keys_too
    hash = build.to_h.transform_keys(&:to_s)
    rebuilt = Post.from_h(hash)

    assert_equal "hello-world", rebuilt.id
  end

  # --- query API -------------------------------------------------------------

  class QueryPost < Andromeda::Entry
    collection :query_test_blog, base: File.expand_path("fixtures/loader/blog", __dir__)

    attribute :title, :string, required: true
    attribute :pub_date, :date, required: true
    attribute :draft, :boolean, default: false

    scope :published, -> { where(draft: false) }
  end

  def teardown
    QueryPost.reload!
  end

  def test_all_returns_every_entry
    assert_equal 3, QueryPost.all.count
  end

  def test_find_returns_the_matching_entry
    assert_equal "Hello World", QueryPost.find("hello-world").title
  end

  def test_find_raises_entry_not_found_for_an_unknown_id
    error = assert_raises(Andromeda::EntryNotFound) { QueryPost.find("does-not-exist") }

    assert_equal :query_test_blog, error.collection
    assert_equal "does-not-exist", error.id
  end

  def test_find_by_matches_on_data
    entry = QueryPost.find_by(title: "Hello World")

    assert_equal "hello-world", entry.id
  end

  def test_where_filters_by_hash_conditions
    drafts = QueryPost.where(draft: true)

    assert_equal 1, drafts.count
    assert_equal "second-post", drafts.first.id
  end

  def test_where_filters_by_block
    long_titles = QueryPost.where { |e| e.title.length > 4 }

    assert(long_titles.count.positive?)
  end

  def test_order_ascending_by_date_attribute
    ids = QueryPost.order(:pub_date).map(&:id)

    assert_equal %w[hello-world second-post nested/deep-post], ids
  end

  def test_order_descending_by_date_attribute
    ids = QueryPost.order(pub_date: :desc).map(&:id)

    assert_equal %w[nested/deep-post second-post hello-world], ids
  end

  def test_limit_caps_the_result_size
    assert_equal 2, QueryPost.order(:pub_date).limit(2).count
  end

  def test_first_without_argument_returns_a_single_entry
    entry = QueryPost.order(:pub_date).first

    assert_equal "hello-world", entry.id
  end

  def test_first_with_argument_returns_an_array
    entries = QueryPost.order(:pub_date).first(2)

    assert_equal 2, entries.size
    assert_kind_of QueryPost, entries.first
  end

  def test_count
    assert_equal 3, QueryPost.count
  end

  def test_scope_at_the_class_level
    assert_equal 2, QueryPost.published.count
  end

  def test_scope_chains_with_further_relation_methods
    ids = QueryPost.published.order(pub_date: :desc).map(&:id)

    assert_equal %w[nested/deep-post hello-world], ids
  end

  def test_unknown_relation_method_still_raises_no_method_error
    assert_raises(NoMethodError) { QueryPost.all.this_scope_does_not_exist }
  end

  # --- reference resolution ---------------------------------------------------

  class RefAuthor < Andromeda::Entry
    collection :ref_test_authors, base: File.expand_path("fixtures/entries/authors", __dir__)
    attribute :name, :string, required: true
  end

  class RefPost < Andromeda::Entry
    collection :ref_test_posts, base: File.expand_path("fixtures/entries/posts", __dir__)
    attribute :title, :string, required: true
    attribute :author, :reference, collection: :ref_test_authors
  end

  def test_reference_resolves_to_the_target_entry
    post = RefPost.find("with-author")

    assert_equal "Jane Doe", post.author.name
  end

  def test_reference_raw_data_holds_the_pointer_not_the_resolved_entry
    post = RefPost.find("with-author")

    assert_instance_of Andromeda::Reference, post.data[:author]
    assert_equal :ref_test_authors, post.data[:author].collection
    assert_equal "jane", post.data[:author].id
  end

  def test_reference_to_a_missing_entry_raises_entry_not_found_naming_both
    post = RefPost.find("missing-author")

    error = assert_raises(Andromeda::EntryNotFound) { post.author }

    assert_equal :ref_test_authors, error.collection
    assert_equal "ghost", error.id
  end

  def test_reference_resolution_is_lazy_not_eager
    RefAuthor.reload!
    post = RefPost.find("with-author")

    # Merely finding/loading `posts` (and even the post's `author`
    # attribute, still holding a Reference struct at this point) must not
    # have forced the `authors` collection to load.
    assert_nil RefAuthor.instance_variable_get(:@entries)

    post.author

    refute_nil RefAuthor.instance_variable_get(:@entries)
  end

  # --- html/headings/index wiring to Andromeda::Pipeline/Store -------
  #
  # Uses a scratch build_path (never the gem's real `.andromeda` default,
  # which would pollute the working directory) for every example here, and
  # always restores the previous config in an `ensure` -- these tests cannot
  # add their own `setup`/`teardown` without silently replacing the ones
  # already defined above for QueryPost/RefAuthor.

  class BuildPost < Andromeda::Entry
    collection :entry_test_build_blog, base: File.expand_path("fixtures/loader/blog", __dir__)

    attribute :title, :string, required: true
    attribute :pub_date, :date, required: true
  end

  def with_scratch_build_path(mode: :development)
    Dir.mktmpdir("andromeda-entry-test") do |dir|
      previous_path = Andromeda.config.build_path
      previous_mode = Andromeda.config.mode
      Andromeda.configure { |config| config.build_path = dir; config.mode = mode }
      BuildPost.reload!
      yield dir
    ensure
      Andromeda.configure { |config| config.build_path = previous_path; config.mode = previous_mode }
      BuildPost.reload!
    end
  end

  def test_html_converts_on_demand_in_development_and_includes_the_rendered_body
    with_scratch_build_path do
      entry = BuildPost.find("hello-world")

      assert_includes entry.html, "This is the first post."
    end
  end

  def test_headings_are_available_alongside_html
    with_scratch_build_path do
      entry = BuildPost.find("hello-world")

      assert_kind_of Array, entry.headings
    end
  end

  def test_html_is_memoized_on_the_instance_so_a_second_call_does_not_reconvert
    with_scratch_build_path do
      entry = BuildPost.find("hello-world")
      entry.html

      Andromeda::Parser.stub(:parse, ->(*) { raise "must not reparse -- already memoized on this instance" }) do
        entry.html
      end
    end
  end

  # Production reads only what the build wrote, so an unbuilt collection
  # fails at the first query rather than later at render time -- the
  # message has to name the fix either way.
  def test_queries_raise_build_missing_in_production_without_a_prior_build
    with_scratch_build_path(mode: :production) do
      error = assert_raises(Andromeda::BuildMissing) { BuildPost.find("hello-world") }

      assert_match(/andromeda:build/, error.message)
    end
  end

  def test_index_reads_the_stored_index_without_reparsing_in_production
    with_scratch_build_path do
      BuildPost.index # dev mode: builds the index from the source files

      Andromeda.configure { |config| config.mode = :production }
      index = nil
      Andromeda::Parser.stub(:parse, ->(*) { raise "production must read the index, never reparse" }) do
        index = BuildPost.index
      end

      assert_equal %w[hello-world nested/deep-post second-post], index.map { |summary| summary[:id] }.sort
    end
  end
end
