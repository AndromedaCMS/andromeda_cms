# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ReferencesTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/references", __dir__)

  class Author < Andromeda::Entry
    collection :references_test_authors, base: File.join(FIXTURES, "authors")
    attribute :name, :string
  end

  class Tag < Andromeda::Entry
    collection :references_test_tags, base: File.join(FIXTURES, "tags")
    attribute :name, :string
  end

  class Post < Andromeda::Entry
    collection :references_test_posts, base: File.join(FIXTURES, "posts")
    attribute :title, :string
    attribute :author, :reference, collection: :references_test_authors
    attribute :tags, :array, of: :reference, collection: :references_test_tags, default: []
  end

  class Orphan < Andromeda::Entry
    collection :references_test_orphans, base: File.join(FIXTURES, "posts")
    attribute :title, :string
    attribute :author, :reference, collection: :references_test_nowhere
  end

  def setup
    [Author, Tag, Post, Orphan].each(&:reload!)
  end

  def test_reports_a_missing_single_reference_and_a_missing_array_element
    problems = Andromeda::References.problems(Post => Post.source_entries)

    assert_equal 2, problems.size
    assert(problems.any? { |p| p.include?("broken.md: author: no :references_test_authors entry with id \"nobody\"") })
    assert(problems.any? { |p| p.include?("broken.md: tags: no :references_test_tags entry with id \"no-such-tag\"") })
    refute(problems.any? { |p| p.include?("good.md") })
  end

  def test_reuses_target_entries_that_are_already_loaded
    problems = Andromeda::References.problems(Post => Post.source_entries, Author => [], Tag => Tag.source_entries)

    assert(problems.any? { |p| p.include?("good.md: author:") }, "an empty loaded Author list means jane does not exist")
  end

  def test_reports_an_unregistered_target_collection
    problems = Andromeda::References.problems(Orphan => Orphan.source_entries)

    assert(problems.all? { |p| p.include?("unknown collection :references_test_nowhere") })
  end

  def test_build_all_fails_on_a_missing_reference_after_writing_what_converted
    Dir.mktmpdir do |dir|
      store = Andromeda::Store.new(build_path: dir)

      error = assert_raises(Andromeda::BuildError) { Andromeda::Pipeline.build_all([Author, Tag, Post], store: store) }

      assert(error.messages.any? { |m| m.include?("no-such-tag") })
      assert_equal %w[broken good], store.read_index(:references_test_posts).map { |s| s[:id] }.sort
    end
  end

  def test_check_reports_a_missing_reference
    problems = Andromeda::Check.run([Author, Tag, Post])

    assert(problems.any? { |p| p.include?("nobody") })
    assert(problems.any? { |p| p.include?("no-such-tag") })
  end
end
