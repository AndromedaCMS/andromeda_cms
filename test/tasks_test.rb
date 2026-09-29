# frozen_string_literal: true

require "test_helper"
require "rake"

# Drives the Rake tasks the way a deploy does, against the dummy application.
class TasksTest < Minitest::Test
  def setup
    @build_path = Dir.mktmpdir("andromeda-build")
    @previous_build_path = Andromeda.config.build_path
    Andromeda.config.build_path = @build_path
    # The tasks operate on every registered collection, and other test files
    # register throwaway ones; narrowing the task's view is safer than
    # mutating the shared registry, which those other tests still rely on.
    Andromeda::Pipeline.define_singleton_method(:default_entry_classes) { [Content::Post] }
    Content::Post.reload!
    load_tasks
  end

  def teardown
    Andromeda.config.build_path = @previous_build_path
    Andromeda::Pipeline.singleton_class.remove_method(:default_entry_classes)
    FileUtils.rm_rf(@build_path)
  end

  def test_build_writes_every_entry_and_the_index
    output = capture_io { run_task("andromeda:build") }.first

    assert_path_exists File.join(@build_path, "blog/hello-world.json")
    assert_path_exists File.join(@build_path, "blog/_index.json")
    assert_match(/converted \d+ entries/, output)
  end

  # A deploy builds in production mode from a clean checkout: a component
  # querying another entry must find it from source (no index exists yet),
  # and an image URL it renders must stay a marker, since the digest is only
  # known after assets:precompile.
  def test_production_build_lets_a_component_find_another_entry_and_its_image
    with_mode(:production) do
      with_extra_content("aaa-card.mdx", <<~MDX) do
        ---
        title: Card
        pub_date: 2026-01-01
        ---

        <PostCard slug="with-hero" />
      MDX
        capture_io { run_task("andromeda:build") }

        html = Andromeda::Store.new(build_path: @build_path).read_entry(:blog, "aaa-card")[:html]
        assert_includes html, "Post with a hero image"
        assert_includes html, %(src="#{Andromeda::Assets::MARKER}andromeda/blog/with-hero/hero.png")
      end
    end
  end

  def test_production_build_converts_an_entry_a_component_embeds_before_its_turn
    with_mode(:production) do
      with_extra_content("aaa-embed.mdx", entry_embedding("with-image")) do
        capture_io { run_task("andromeda:build") }

        html = Andromeda::Store.new(build_path: @build_path).read_entry(:blog, "aaa-embed")[:html]
        assert_includes html, %(src="#{Andromeda::Assets::MARKER}andromeda/blog/with-image/cover.png")
      end
    end
  end

  def test_build_lists_an_unknown_entry_queried_by_a_component_with_the_other_problems
    with_extra_content("aaa-card.mdx", <<~MDX) do
      ---
      title: Card
      pub_date: 2026-01-01
      ---

      <PostCard slug="nope" />
    MDX
      error = assert_raises(Andromeda::BuildError) { Andromeda::Pipeline.build_all }

      assert_includes error.message, "aaa-card.mdx"
      assert_includes error.message, %(no :blog entry with id "nope")
    end
  end

  def test_build_reports_entries_whose_components_embed_each_other
    with_extra_content("aaa-loop-a.mdx", entry_embedding("aaa-loop-b")) do
      with_extra_content("aaa-loop-b.mdx", entry_embedding("aaa-loop-a")) do
        error = assert_raises(Andromeda::BuildError) { Andromeda::Pipeline.build_all }

        assert_includes error.message, "circular conversion: blog/aaa-loop-a -> blog/aaa-loop-b -> blog/aaa-loop-a"
      end
    end
  end

  def test_clobber_removes_the_build_directory
    run_task("andromeda:build")
    capture_io { run_task("andromeda:clobber") }

    refute_path_exists @build_path
  end

  def test_build_is_wired_into_assets_precompile
    assert_includes Rake::Task["assets:precompile"].prerequisites, "andromeda:build"
    assert_includes Rake::Task["assets:clobber"].prerequisites, "andromeda:clobber"
  end

  def test_check_reports_a_non_snake_case_key_and_writes_nothing
    with_extra_content("camel-case.md", <<~MD) do
      ---
      title: Camel
      pubDate: 2026-01-01
      pub_date: 2026-01-01
      ---

      Body.
    MD
      problems = Andromeda::Check.run([Content::Post])

      assert(problems.any? { |problem| problem.include?("pubDate") && problem.include?("andromeda:fix") })
      refute_path_exists File.join(@build_path, "blog/camel-case.json"), "check must not write"
    end
  end

  def test_check_reports_a_missing_component
    with_extra_content("missing-component.mdx", <<~MDX) do
      ---
      title: Missing
      pub_date: 2026-01-01
      ---

      <NoSuchComponent />
    MDX
      problems = Andromeda::Check.run([Content::Post])

      assert(problems.any? { |problem| problem.include?("NoSuchComponent") })
    end
  end

  def test_check_reports_a_missing_asset_pipeline_image
    with_extra_content("missing-asset.md", <<~MD) do
      ---
      title: Missing asset
      pub_date: 2026-01-01
      ---

      ![](blog/posts/missing.png)
    MD
      problems = Andromeda::Check.run([Content::Post])

      assert(problems.any? { |problem| problem.include?('"blog/posts/missing.png" is not in the asset pipeline') })
    end
  end

  def test_check_reports_a_missing_relative_image
    with_extra_content("missing-relative.md", <<~MD) do
      ---
      title: Missing relative
      pub_date: 2026-01-01
      ---

      ![](./nope.png)
    MD
      problems = Andromeda::Check.run([Content::Post])

      assert(problems.any? { |problem| problem.include?('"./nope.png" does not exist') })
    end
  end

  def test_fix_rewrites_keys_and_leaves_the_rest_byte_identical
    source = <<~MD
      ---
      title: Camel
      pubDate: 2026-01-01
      hero-image: ./x.png
      nested:
        keepMe: 1
      ---

      Body with `pubDate` mentioned in prose.
    MD

    with_extra_content("fixable.md", source) do
      changes = Andromeda::Fix.run([Content::Post])
      fixed = File.read(content_path("fixable.md"))

      assert_equal 2, changes.size
      assert_includes fixed, "pub_date: 2026-01-01"
      assert_includes fixed, "hero_image: ./x.png"
      assert_includes fixed, "keepMe: 1", "nested keys belong to a structure the schema does not describe"
      assert_includes fixed, "Body with `pubDate` mentioned in prose."
    end
  end

  private

  def load_tasks
    return if Rake::Task.task_defined?("andromeda:build")

    Rake::Task.define_task(:environment)
    Rails.application.load_tasks
  end

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  def content_path(name)
    Rails.root.join("app/content/blog", name).to_s
  end

  def entry_embedding(slug)
    <<~MDX
      ---
      title: Embed #{slug}
      pub_date: 2026-01-01
      ---

      <PostEmbed slug="#{slug}" />
    MDX
  end

  def with_mode(mode)
    previous = Andromeda.config.mode
    Andromeda.config.mode = mode
    Content::Post.reload!
    yield
  ensure
    Andromeda.config.mode = previous
    Content::Post.reload!
  end

  def with_extra_content(name, source)
    File.write(content_path(name), source)
    Content::Post.reload!
    yield
  ensure
    FileUtils.rm_f(content_path(name))
    Content::Post.reload!
  end
end
