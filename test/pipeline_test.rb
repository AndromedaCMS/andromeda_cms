# frozen_string_literal: true

require "test_helper"
require "date"
require "tmpdir"
require "fileutils"

class PipelineTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/pipeline", __dir__)

  # A stand-in for Andromeda::Components: records every call instead of
  # touching ApplicationController.renderer, so these tests don't need a
  # Rails view layer to exercise "components get expanded for .mdx".
  class StubComponents
    Call = Struct.new(:name, :attrs, :children_html, :node, keyword_init: false)

    class << self
      attr_accessor :last_instance
    end

    attr_reader :tree, :path, :frontmatter, :calls

    def initialize(tree:, path: nil, view: nil, frontmatter: {})
      @tree = tree
      @path = path
      @view = view
      @frontmatter = frontmatter
      @calls = []
      self.class.last_instance = self
    end

    def render(name, attrs, children_html, node)
      @calls << Call.new(name, attrs, children_html, node)
      "<stub name=\"#{name}\">#{children_html}</stub>"
    end
  end

  def setup
    @dir = Dir.mktmpdir("andromeda-pipeline-test")
    @store = Andromeda::Store.new(build_path: @dir)
    StubComponents.last_instance = nil
    stub_components!
  end

  def teardown
    restore_components!
    FileUtils.remove_entry(@dir)
  end

  # --- fixtures / helpers ------------------------------------------------------

  # Registered once, at class-definition time, like Andromeda::Entry
  # subclasses normally are -- so `.collection_name` is a real Symbol
  # (Store needs one to build a path) rather than nil, the way it would be
  # for a schema-only subclass built the way LoaderTest's are.
  #
  # NOTE: this registers into the process-wide Andromeda::Registry, same as
  # every other file's Entry subclasses do; nothing here ever calls
  # `Registry.clear!` (that would wipe *every* other test file's
  # registrations too, since Registry is global state shared for the whole
  # test run -- see Andromeda::Registry's own module comment).
  class BlogPost < Andromeda::Entry
    collection :pipeline_test_blog, base: File.join(FIXTURES, "blog")
    attribute :title, :string, required: true
    attribute :pub_date, :date, required: true
  end

  class NotesPost < Andromeda::Entry
    collection :pipeline_test_notes, base: File.join(FIXTURES, "notes")
    attribute :title, :string, required: true
    attribute :pub_date, :date, required: true
  end

  def hello_world_entry
    BlogPost.reload!
    BlogPost.find("hello-world")
  end

  def with_component_entry
    BlogPost.reload!
    BlogPost.find("with-component")
  end

  def pipeline(mode: :development)
    Andromeda::Pipeline.new(store: @store, mode: mode)
  end

  def stub_components!
    @had_original_components = Andromeda.const_defined?(:Components, false)
    @original_components = Andromeda.const_get(:Components) if @had_original_components
    Andromeda.send(:remove_const, :Components) if @had_original_components
    Andromeda.const_set(:Components, StubComponents)
  end

  def restore_components!
    Andromeda.send(:remove_const, :Components) if Andromeda.const_defined?(:Components, false)
    Andromeda.const_set(:Components, @original_components) if @had_original_components
  end

  # --- convert -----------------------------------------------------------------

  def test_convert_renders_html_and_headings_and_writes_to_the_store
    entry = hello_world_entry
    payload = pipeline.convert(entry)

    assert_includes payload[:html], "<h1"
    assert_includes payload[:html], "Hello World"
    assert_equal [{ depth: 1, slug: "hello-world", text: "Hello World" }], payload[:headings]
    assert_equal entry.digest, payload[:digest]
    assert_equal entry.data, payload[:data]
    assert_equal entry.file_path, payload[:file_path]

    assert_equal payload, @store.read_entry(:pipeline_test_blog, "hello-world")
  end

  def test_convert_expands_mdx_components_via_the_injected_stub
    entry = with_component_entry
    payload = pipeline.convert(entry)

    call = StubComponents.last_instance.calls.first
    refute_nil call, "expected the components stub to be called"
    assert_equal "Callout", call.name
    assert_equal "tip", call.attrs["type"]
    assert_includes payload[:html], '<stub name="Callout">'
  end

  def test_convert_never_touches_components_for_plain_markdown
    pipeline.convert(hello_world_entry)

    assert_nil StubComponents.last_instance
  end

  # --- fetch: development mode ---------------------------------------------------

  def test_fetch_converts_and_stores_when_nothing_is_stored_yet
    entry = hello_world_entry
    assert_nil @store.read_entry(entry.collection, entry.id)

    result = pipeline.fetch(entry)

    assert_includes result[:html], "Hello World"
    refute_nil @store.read_entry(entry.collection, entry.id)
  end

  def test_fetch_does_not_reparse_when_the_stored_digest_still_matches
    entry = hello_world_entry
    pipeline.fetch(entry) # first call: converts and stores

    Andromeda::Parser.stub(:parse, ->(*) { raise "must not reparse an unchanged file" }) do
      result = pipeline.fetch(entry)
      assert_includes result[:html], "Hello World"
    end
  end

  def test_fetch_reconverts_when_the_source_digest_changed
    Dir.mktmpdir do |source_dir|
      write(source_dir, "post.md", frontmatter_body("Original"))
      entry = load_entries_in(source_dir).first
      pipeline.fetch(entry)

      write(source_dir, "post.md", frontmatter_body("Changed"))
      changed_entry = load_entries_in(source_dir).first
      refute_equal entry.digest, changed_entry.digest

      result = pipeline.fetch(changed_entry)
      assert_includes result[:html], "Changed"
      assert_equal changed_entry.digest, @store.read_entry(changed_entry.collection, changed_entry.id)[:digest]
    end
  end

  def test_fetch_ignores_an_unrelated_stored_digest_for_a_different_entry
    # Converting one entry must not make another entry (never converted, so
    # its digest is not yet stored at all) look "stale" -- each id's
    # staleness check is independent.
    pipeline.convert(hello_world_entry)

    other = with_component_entry
    assert_nil @store.read_entry(other.collection, other.id)
  end

  # --- fetch: production mode -----------------------------------------------------

  def test_fetch_in_production_raises_build_missing_when_nothing_is_stored
    entry = hello_world_entry
    error = assert_raises(Andromeda::BuildMissing) { pipeline(mode: :production).fetch(entry) }

    assert_match(/andromeda:build/, error.message)
    assert_match(/assets:precompile/, error.message)
    assert_equal entry.collection, error.collection
    assert_equal entry.id, error.id
  end

  def test_fetch_in_production_reads_the_stored_result_without_reconverting_even_if_stale
    entry = hello_world_entry
    @store.write_entry(entry.collection, entry.id, {
      id: entry.id, collection: entry.collection, data: entry.data,
      html: "<p>STALE</p>\n", headings: [], digest: "not-the-current-digest", file_path: entry.file_path
    })

    result = nil
    Andromeda::Parser.stub(:parse, ->(*) { raise "production must never reconvert on read" }) do
      result = pipeline(mode: :production).fetch(entry)
    end

    assert_equal "<p>STALE</p>\n", result[:html]
  end

  # --- collection_index ------------------------------------------------------------

  def test_collection_index_in_production_reads_the_stored_index
    klass = Class.new(Andromeda::Entry) do
      collection :"pipeline_index_prod_#{object_id}", base: File.join(FIXTURES, "blog")
      attribute :title, :string, required: true
      attribute :pub_date, :date, required: true
    end
    pipeline.build_collection(klass) # populate the store first, via a dev-mode pipeline

    index = pipeline(mode: :production).collection_index(klass)
    assert_equal %w[hello-world with-component], index.map { |s| s[:id] }.sort
  end

  def test_collection_index_in_production_raises_build_missing_when_absent
    klass = Class.new(Andromeda::Entry) do
      collection :"pipeline_index_prod_missing_#{object_id}", base: File.join(FIXTURES, "blog")
      attribute :title, :string, required: true
      attribute :pub_date, :date, required: true
    end

    assert_raises(Andromeda::BuildMissing) { pipeline(mode: :production).collection_index(klass) }
  end

  def test_collection_index_in_development_reflects_a_deleted_source_file
    Dir.mktmpdir do |source_dir|
      write(source_dir, "keep.md", frontmatter_body("Keep"))
      write(source_dir, "remove.md", frontmatter_body("Remove"))

      klass = Class.new(Andromeda::Entry) do
        collection :"pipeline_index_dev_#{object_id}", base: source_dir
        attribute :title, :string, required: true
        attribute :pub_date, :date, required: true
      end

      pipeline.collection_index(klass)
      assert_equal %w[keep remove], @store.read_index(klass.collection_name).map { |s| s[:id] }.sort

      File.delete(File.join(source_dir, "remove.md"))
      klass.reload!
      index = pipeline.collection_index(klass)

      assert_equal %w[keep], index.map { |s| s[:id] }
      refute File.file?(@store.entry_path(klass.collection_name, "remove"))
    end
  end

  # --- build_collection / build_all -------------------------------------------------

  def test_build_collection_writes_every_entry_and_reports_no_errors
    BlogPost.reload!
    result = pipeline.build_collection(BlogPost)

    assert result.success?
    assert_equal 2, result.converted
    assert_equal %w[hello-world with-component], @store.read_index(:pipeline_test_blog).map { |s| s[:id] }.sort
  end

  def test_build_collection_reports_a_schema_problem_without_writing_anything
    NotesPost.reload!
    result = pipeline.build_collection(NotesPost)

    refute result.success?
    assert_equal 0, result.converted
    assert(result.errors.any? { |m| m.include?("bad.md") && m.include?("title") })
  end

  def test_build_all_reports_every_collection_problem_together
    BlogPost.reload!
    NotesPost.reload!

    error = assert_raises(Andromeda::BuildError) { Andromeda::Pipeline.build_all([BlogPost, NotesPost], store: @store) }

    assert(error.messages.any? { |m| m.include?("pipeline_test_notes") })
  end

  def test_build_all_still_writes_the_clean_collection_despite_the_other_ones_failure
    BlogPost.reload!
    NotesPost.reload!

    Andromeda::Pipeline.build_all([BlogPost, NotesPost], store: @store)
  rescue Andromeda::BuildError
    assert_equal %w[hello-world with-component], @store.read_index(:pipeline_test_blog).map { |s| s[:id] }.sort
  end

  # A deploy builds in production mode from a clean checkout, where the built
  # index Entry.all reads in production does not exist yet.
  def test_build_collection_in_production_mode_reads_source_files_before_anything_is_built
    in_production_mode(build_path: Dir.mktmpdir("andromeda-empty-build")) do
      BlogPost.reload!
      result = pipeline(mode: :production).build_collection(BlogPost)

      assert result.success?
      assert_equal 2, result.converted
    end
  end

  # A second production build must convert the source again: the built index
  # carries no body, so converting its entries would blank every page.
  def test_rebuilding_in_production_mode_keeps_every_page_body
    BlogPost.reload!
    pipeline.build_collection(BlogPost)

    in_production_mode(build_path: @dir) do
      BlogPost.reload!
      pipeline(mode: :production).build_collection(BlogPost)
    end

    assert_includes @store.read_entry(:pipeline_test_blog, "hello-world")[:html], "<h1"
  end

  # Production entries come from the index, which carries no body; the body is
  # read back from the entry's built file instead, as `html` is.
  def test_body_is_available_in_production_mode_from_the_built_entry
    BlogPost.reload!
    pipeline.build_collection(BlogPost)

    in_production_mode(build_path: @dir) do
      BlogPost.reload!
      assert_includes BlogPost.find("hello-world").body, "# Hello World"
    end
  end

  def test_the_index_leaves_bodies_out
    BlogPost.reload!
    pipeline.build_collection(BlogPost)

    assert(@store.read_index(:pipeline_test_blog).none? { |summary| summary.key?(:body) })
    assert_includes @store.read_entry(:pipeline_test_blog, "hello-world")[:body], "# Hello World"
  end

  def test_build_all_with_only_clean_collections_writes_everything
    BlogPost.reload!
    results = Andromeda::Pipeline.build_all([BlogPost], store: @store)

    assert(results.all?(&:success?))
    assert_equal 2, results.first.converted
  end

  # --- fetch: what else the stored HTML depends on ------------------------------

  # Partials are baked into the HTML at conversion time; a stored copy made
  # with the old partial must not outlive an edit to it.
  def test_fetch_reconverts_when_a_component_partial_changed
    with_project_root do |root|
      partial = File.join(root, Andromeda.config.components_path, "_callout.html.erb")
      FileUtils.mkdir_p(File.dirname(partial))
      File.write(partial, "old")
      entry = hello_world_entry
      pipeline.fetch(entry)

      File.write(partial, "new markup")
      File.utime(Time.now + 5, Time.now + 5, partial)

      reparsed = false
      original = Andromeda::Parser.method(:parse)
      Andromeda::Parser.stub(:parse, ->(*args, **kwargs) { reparsed = true; original.call(*args, **kwargs) }) do
        pipeline.fetch(entry)
      end
      assert reparsed, "an edited partial must invalidate the stored HTML"
    end
  end

  def test_fetch_reconverts_when_the_highlight_theme_changed
    with_project_root do
      entry = hello_world_entry
      pipeline.fetch(entry)
      previous = Andromeda.config.highlight_theme
      Andromeda.config.highlight_theme = "github.light"

      Andromeda::Parser.stub(:parse, ->(*) { raise "reparsed" }) do
        assert_raises(RuntimeError) { pipeline.fetch(entry) }
      end
    ensure
      Andromeda.config.highlight_theme = previous
    end
  end

  def test_fetch_keeps_the_stored_copy_when_nothing_it_depends_on_changed
    with_project_root do |root|
      partial = File.join(root, Andromeda.config.components_path, "_callout.html.erb")
      FileUtils.mkdir_p(File.dirname(partial))
      File.write(partial, "same")
      entry = hello_world_entry
      pipeline.fetch(entry)

      Andromeda::Parser.stub(:parse, ->(*) { raise "must not reparse" }) do
        assert_includes pipeline.fetch(entry)[:html], "Hello World"
      end
    end
  end

  private

  def load_entries_in(dir)
    Andromeda::Loader.new(entry_class: BlogPost, base: dir, pattern: "**/*.md", schema: BlogPost.schema).load
  end

  def write(dir, name, content)
    File.write(File.join(dir, name), content)
  end

  def frontmatter_body(text)
    "---\ntitle: #{text}\npub_date: 2022-01-01\n---\n#{text}\n"
  end

  def in_production_mode(build_path:)
    previous = [Andromeda.config.mode, Andromeda.config.build_path]
    Andromeda.config.mode = :production
    Andromeda.config.build_path = build_path
    yield
  ensure
    Andromeda.config.mode, Andromeda.config.build_path = previous
    BlogPost.reload!
  end

  def with_project_root
    previous = Andromeda.config.instance_variable_get(:@project_root)
    Dir.mktmpdir("andromeda-pipeline-root") do |root|
      Andromeda.config.project_root = root
      yield root
    end
  ensure
    Andromeda.config.project_root = previous
  end
end
