# frozen_string_literal: true

require "test_helper"
require "date"
require "tmpdir"
require "fileutils"

class StoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("andromeda-store-test")
    @store = Andromeda::Store.new(build_path: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def payload(id: "hello-world", collection: :blog, digest: "abc123")
    {
      id: id, collection: collection,
      data: { title: "Hello World", pub_date: Date.new(2022, 7, 8) },
      html: "<p>Hello World</p>\n",
      headings: [{ depth: 1, slug: "hello-world", text: "Hello World" }],
      digest: digest,
      file_path: "/tmp/content/#{id}.md"
    }
  end

  # --- paths -----------------------------------------------------------------

  def test_entry_path_is_nested_under_build_path_and_collection
    path = @store.entry_path(:blog, "hello-world")

    assert_equal File.join(@dir, "blog", "hello-world.json"), path
  end

  def test_entry_path_creates_nested_directories_for_ids_containing_slashes
    @store.write_entry(:blog, "nested/deep-post", payload(id: "nested/deep-post"))

    assert File.file?(File.join(@dir, "blog", "nested", "deep-post.json"))
  end

  def test_index_path_is_per_collection
    assert_equal File.join(@dir, "blog", "_index.json"), @store.index_path(:blog)
  end

  # --- round trip --------------------------------------------------------------

  def test_write_then_read_round_trips_the_full_payload
    written = payload
    @store.write_entry(:blog, "hello-world", written)
    read_back = @store.read_entry(:blog, "hello-world")

    assert_equal written, read_back
  end

  def test_round_trip_preserves_date_values_in_data_not_just_their_string_form
    @store.write_entry(:blog, "hello-world", payload)
    read_back = @store.read_entry(:blog, "hello-world")

    assert_kind_of Date, read_back[:data][:pub_date]
    assert_equal Date.new(2022, 7, 8), read_back[:data][:pub_date]
  end

  def test_round_trip_preserves_reference_and_image_attribute_values
    entry_payload = payload
    entry_payload[:data] = {
      author: Andromeda::Reference.new(collection: :authors, id: "jane"),
      cover: Andromeda::Image.new(path: "/abs/cover.png", relative_path: "cover.png")
    }
    @store.write_entry(:blog, "hello-world", entry_payload)
    read_back = @store.read_entry(:blog, "hello-world")

    assert_instance_of Andromeda::Reference, read_back[:data][:author]
    assert_equal :authors, read_back[:data][:author].collection
    assert_equal "jane", read_back[:data][:author].id

    assert_instance_of Andromeda::Image, read_back[:data][:cover]
    assert_equal "cover.png", read_back[:data][:cover].relative_path
  end

  def test_round_trip_preserves_an_array_of_references_built_by_the_schema
    schema = Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :reference, collection: :tags }
    entry_payload = payload
    entry_payload[:data] = schema.validate({ "tags" => ["exam-prep"] }).data
    @store.write_entry(:blog, "hello-world", entry_payload)
    read_back = @store.read_entry(:blog, "hello-world")

    assert_equal [Andromeda::Reference.new(collection: :tags, id: "exam-prep")], read_back[:data][:tags]
  end

  def test_read_entry_returns_nil_when_nothing_was_ever_written
    assert_nil @store.read_entry(:blog, "does-not-exist")
  end

  def test_read_entry_returns_nil_instead_of_raising_on_a_corrupt_file
    path = @store.entry_path(:blog, "hello-world")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{not valid json")

    assert_nil @store.read_entry(:blog, "hello-world")
  end

  # --- index -------------------------------------------------------------------

  def test_write_entry_adds_a_summary_to_the_index
    @store.write_entry(:blog, "hello-world", payload)
    index = @store.read_index(:blog)

    assert_equal 1, index.size
    summary = index.first
    assert_equal "hello-world", summary[:id]
    assert_equal({ title: "Hello World", pub_date: Date.new(2022, 7, 8) }, summary[:data])
    assert_equal [{ depth: 1, slug: "hello-world", text: "Hello World" }], summary[:headings]
    assert_equal "abc123", summary[:digest]
    assert_equal "/tmp/content/hello-world.md", summary[:file_path]
  end

  def test_index_summary_does_not_include_html
    @store.write_entry(:blog, "hello-world", payload)

    refute_includes @store.read_index(:blog).first.keys, :html
  end

  def test_write_entry_merges_with_other_entries_already_in_the_index
    @store.write_entry(:blog, "a", payload(id: "a"))
    @store.write_entry(:blog, "b", payload(id: "b"))

    ids = @store.read_index(:blog).map { |summary| summary[:id] }
    assert_equal %w[a b], ids.sort
  end

  def test_write_entry_updates_an_existing_summary_rather_than_duplicating_it
    @store.write_entry(:blog, "a", payload(id: "a", digest: "old"))
    @store.write_entry(:blog, "a", payload(id: "a", digest: "new"))

    index = @store.read_index(:blog)
    assert_equal 1, index.size
    assert_equal "new", index.first[:digest]
  end

  def test_read_index_returns_nil_when_never_written
    assert_nil @store.read_index(:blog)
  end

  # --- replace_collection! (build_all / dev refresh) ----------------------------

  def test_replace_collection_writes_every_entry_and_the_index
    @store.replace_collection!(:blog, [payload(id: "a"), payload(id: "b")])

    assert File.file?(@store.entry_path(:blog, "a"))
    assert File.file?(@store.entry_path(:blog, "b"))
    assert_equal %w[a b], @store.read_index(:blog).map { |s| s[:id] }.sort
  end

  def test_replace_collection_prunes_entries_no_longer_present
    @store.replace_collection!(:blog, [payload(id: "a"), payload(id: "b")])
    @store.replace_collection!(:blog, [payload(id: "a")]) # "b"'s source file was deleted

    refute File.file?(@store.entry_path(:blog, "b"))
    assert_equal %w[a], @store.read_index(:blog).map { |s| s[:id] }
  end

  def test_replace_collection_with_an_empty_list_clears_the_collection
    @store.replace_collection!(:blog, [payload(id: "a")])
    @store.replace_collection!(:blog, [])

    refute File.file?(@store.entry_path(:blog, "a"))
    assert_empty @store.read_index(:blog)
  end

  # --- id / collection safety ----------------------------------------------------

  def test_id_containing_dot_dot_cannot_escape_the_build_directory
    assert_raises(Andromeda::Error) { @store.entry_path(:blog, "../../etc/passwd") }
  end

  def test_write_entry_with_a_traversal_id_raises_instead_of_writing_outside_build_path
    outside = File.expand_path(File.join(@dir, "..", "escaped.json"))

    assert_raises(Andromeda::Error) { @store.write_entry(:blog, "../escaped", payload(id: "../escaped")) }
    refute File.file?(outside)
  end

  def test_collection_name_containing_dot_dot_cannot_escape_the_build_directory
    assert_raises(Andromeda::Error) { @store.entry_path("../escaped", "x") }
  end

  # --- atomicity -----------------------------------------------------------------

  def test_write_goes_through_a_temp_file_before_the_final_path_exists
    written_paths = []
    renamed = []
    original_write = File.method(:write)
    original_rename = File.method(:rename)

    File.define_singleton_method(:write) do |path, content|
      written_paths << path
      original_write.call(path, content)
    end
    File.define_singleton_method(:rename) do |from, to|
      renamed << [from, to]
      original_rename.call(from, to)
    end

    @store.write_entry(:blog, "hello-world", payload)

    # write_entry touches two files (the entry itself, and its collection's
    # _index.json) -- both must go through the write-then-rename dance, and
    # neither's *final* path may ever appear as something `File.write` wrote
    # to directly.
    final_paths = [@store.entry_path(:blog, "hello-world"), @store.index_path(:blog)]
    assert_equal 2, written_paths.size
    assert_empty(written_paths & final_paths, "content must be written to a temp file, not the final path")
    assert_equal final_paths.sort, renamed.map(&:last).sort
    assert_equal written_paths.sort, renamed.map(&:first).sort
  ensure
    File.define_singleton_method(:write, original_write)
    File.define_singleton_method(:rename, original_rename)
  end

  def test_a_failed_write_never_leaves_a_stray_temp_file_or_a_partial_final_file
    original_write = File.method(:write)
    File.define_singleton_method(:write) { |*| raise IOError, "disk full (simulated)" }

    assert_raises(IOError) { @store.write_entry(:blog, "hello-world", payload) }

    dir = File.join(@dir, "blog")
    leftovers = File.directory?(dir) ? Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) } : []
    assert_empty leftovers
  ensure
    File.define_singleton_method(:write, original_write)
  end

  def test_a_failed_write_does_not_disturb_a_previously_written_entry
    @store.write_entry(:blog, "hello-world", payload(digest: "first"))

    original_write = File.method(:write)
    File.define_singleton_method(:write) { |*| raise IOError, "disk full (simulated)" }
    assert_raises(IOError) { @store.write_entry(:blog, "hello-world", payload(digest: "second")) }
    File.define_singleton_method(:write, original_write)

    assert_equal "first", @store.read_entry(:blog, "hello-world")[:digest]
  end

  # --- concurrent writers ---------------------------------------------------------

  # Development converts on demand from several Puma threads at once; each
  # one folds its entry into the shared index, and none may be lost.
  def test_concurrent_write_entry_keeps_every_entry_in_the_index
    ids = (1..20).map { |i| "entry-#{i}" }
    ids.map { |id| Thread.new { @store.write_entry(:blog, id, payload(id: id)) } }.each(&:join)

    indexed = JSON.parse(File.read(@store.index_path(:blog))).map { |summary| summary["id"] }
    assert_equal ids.sort, indexed.sort
  end

  def test_the_index_lock_file_survives_a_full_rebuild
    @store.write_entry(:blog, "a", payload(id: "a"))
    @store.replace_collection!(:blog, [payload(id: "b")])

    indexed = JSON.parse(File.read(@store.index_path(:blog))).map { |summary| summary["id"] }
    assert_equal ["b"], indexed
    refute File.exist?(@store.entry_path(:blog, "a")), "orphaned entry should be pruned"
  end
end
