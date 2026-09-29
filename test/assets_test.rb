# frozen_string_literal: true

require "test_helper"

class AssetsTest < Minitest::Test
  def setup
    Content::Post.reload!
    FileUtils.rm_rf(builds_dir)
    # A stored conversion would be served as-is, and publishing images is part
    # of converting -- so both have to start empty for these assertions.
    FileUtils.rm_rf(Rails.root.join(Andromeda.config.build_path))
  end

  def teardown
    FileUtils.rm_rf(builds_dir)
    FileUtils.rm_rf(Rails.root.join(Andromeda.config.build_path))
  end

  def test_a_colocated_image_is_published_and_marked_for_the_view_to_resolve
    html = Content::Post.find("with-image").html

    assert_includes html, "andromeda-asset:andromeda/blog/with-image/cover.png"
    assert_path_exists builds_dir.join("andromeda/blog/with-image/cover.png")
  end

  # The digest is only known once the asset pipeline has indexed the copy, so
  # resolution happens in the view rather than during conversion.
  def test_the_view_resolves_the_marker_into_an_asset_url
    resolved = Andromeda::Assets.resolve(Content::Post.find("with-image").html)

    assert_match %r{src="/assets/andromeda/blog/with-image/cover[-.]}, resolved
    refute_includes resolved, Andromeda::Assets::MARKER
  end

  # A listing links hero images without rendering any bodies, so the asset
  # reference has to exist before conversion; the file itself is copied when
  # the entry is converted.
  def test_a_frontmatter_image_gets_its_asset_reference_without_conversion
    image = Content::Post.find("with-hero").hero_image

    assert_includes image.asset, "andromeda/blog/with-hero/hero.png"
    refute_path_exists builds_dir.join("andromeda/blog/with-hero/hero.png")
  end

  def test_converting_publishes_frontmatter_images
    entry = Content::Post.find("with-hero")
    entry.html

    assert_path_exists builds_dir.join("andromeda/blog/with-hero/hero.png")
    assert_match %r{/assets/andromeda/blog/with-hero/hero[-.]}, Andromeda::Assets.resolve(entry.hero_image.asset)
  end

  def test_a_path_escaping_the_project_is_not_published
    resolver = Andromeda::Pipeline.new.send(:image_resolver_for, Content::Post.find("with-image"))

    error = assert_raises(Andromeda::Error) { resolver.call("#{"../" * 30}etc/passwd", nil) }
    assert_match(/resolves outside the project/, error.message)
    refute Dir.glob(builds_dir.join("**/passwd")).any?, "nothing outside the project may be published"
  end

  # An application's own assets and anything in public/ must keep working:
  # the first goes through the pipeline (and gets a digest), the second is
  # already a URL.
  def test_images_the_application_already_ships_are_resolved_through_the_pipeline
    html = Andromeda::Assets.resolve(Content::Post.find("existing-images").html)

    assert_match %r{src="/assets/logo[-.]}, html
    assert_includes html, %(src="/banner.png")
    assert_includes html, %(src="https://example.com/remote.png")
  end

  def test_remote_and_absolute_urls_are_left_alone
    resolver = Andromeda::Pipeline.new.send(:image_resolver_for, Content::Post.find("with-image"))

    assert_equal "https://example.com/a.png", resolver.call("https://example.com/a.png", nil)
    assert_equal "/logo.png", resolver.call("/logo.png", nil)
  end

  def test_a_missing_relative_image_fails_instead_of_falling_back_to_the_pipeline
    resolver = Andromeda::Pipeline.new.send(:image_resolver_for, Content::Post.find("with-image"))
    node = { position: { start: { line: 3, column: 1 } } }

    error = assert_raises(Andromeda::Error) { resolver.call("./nope.png", node) }
    assert_equal '3:1: image "./nope.png" does not exist', error.message
    assert_raises(Andromeda::Error) { resolver.call("../nope.png", nil) }
  end

  def test_a_bare_path_still_falls_back_to_the_asset_pipeline
    resolver = Andromeda::Pipeline.new.send(:image_resolver_for, Content::Post.find("with-image"))

    assert_equal "andromeda-asset:logo.png", resolver.call("logo.png", nil)
  end

  def test_publishing_twice_does_not_recopy_an_unchanged_file
    source = Rails.root.join("app/content/blog/with-image/cover.png").to_s
    root = Rails.root.join("app/content/blog").to_s

    logical = Andromeda::Assets.publish(source, content_root: root)
    copied = builds_dir.join(logical)
    first = copied.mtime

    Andromeda::Assets.publish(source, content_root: root)

    assert_equal first, copied.mtime
  end


  # A checkout or an extracted archive can hand a changed image an old mtime;
  # only the bytes say whether the published copy is current.
  def test_a_same_sized_edit_with_an_older_mtime_is_still_republished
    Dir.mktmpdir do |dir|
      source = File.join(dir, "blog/post/cover.png")
      FileUtils.mkdir_p(File.dirname(source))
      File.binwrite(source, "AAAA")
      logical = Andromeda::Assets.publish(source, content_root: File.join(dir, "blog"))
      copied = builds_dir.join(logical)

      File.binwrite(source, "BBBB")
      File.utime(Time.at(0), Time.at(0), source)
      Andromeda::Assets.publish(source, content_root: File.join(dir, "blog"))

      assert_equal "BBBB", File.binread(copied)
    ensure
      FileUtils.rm_rf(builds_dir.join("andromeda"))
    end
  end

  private

  def builds_dir
    Rails.root.join("app/assets/builds")
  end
end
