# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "generators/andromeda/import_astro/import_astro_generator"

# The migration path's real acceptance test: Astro's own `examples/blog`
# must import and then render, unmodified.
class ImportAstroEndToEndTest < Minitest::Test
  # A vendored copy of Astro's own examples/blog, so this acceptance test runs
  # anywhere the gem is checked out (see the fixture's README).
  ASTRO_PROJECT = File.expand_path("fixtures/astro_blog_example", __dir__)

  def setup
    @app = Dir.mktmpdir("andromeda-import")
    @previous_project_root = Andromeda.config.project_root
    # Loading the generated class registers its collection; other suites rely
    # on their own registrations surviving this one.
    @previous_registry = Andromeda::Registry.collection_names.to_h { |name| [name, Andromeda::Registry[name]] }
    # The imported app is the project for the duration of this test, which is
    # what makes `../../assets/...` (Astro's own layout) resolve.
    Andromeda.config.project_root = @app
    run_generator
  end

  def teardown
    FileUtils.rm_rf(@app) if @app
    Andromeda.config.project_root = @previous_project_root
    Andromeda::Registry.clear!
    @previous_registry&.each { |name, entry_class| Andromeda::Registry.register(name, entry_class) }
  end

  def test_imports_astros_own_blog_example
    assert_path_exists File.join(@app, "app/content/blog/first-post.md")
    assert_path_exists File.join(@app, "app/content/blog/using-mdx.mdx")
    assert_path_exists File.join(@app, "app/models/content/blog.rb")
  end

  def test_rewrites_frontmatter_keys_but_keeps_the_body_identical
    imported = File.read(File.join(@app, "app/content/blog/first-post.md"))
    original = File.read("#{ASTRO_PROJECT}/src/content/blog/first-post.md")

    assert_includes imported, "pub_date:"
    refute_includes imported, "pubDate:"
    assert_equal original.split(/^---$/, 3).last, imported.split(/^---$/, 3).last
  end

  def test_rewrites_the_mdx_import_to_a_partial_path
    imported = File.read(File.join(@app, "app/content/blog/using-mdx.mdx"))

    import_line = imported.lines.find { |line| line.start_with?("import ") }

    assert_equal %(import HeaderLink from 'content_components/header_link';\n), import_line
  end

  def test_generated_schema_validates_every_imported_entry
    entry_class = load_generated_entry_class

    entries = entry_class.all.to_a

    assert_equal 5, entries.size
    assert(entries.all? { |entry| entry.title.is_a?(String) })
    assert(entries.all? { |entry| entry.data[:pub_date].is_a?(Date) })
  end

  def test_every_imported_markdown_entry_converts
    entry_class = load_generated_entry_class

    %w[first-post second-post third-post markdown-style-guide].each do |id|
      html = convert(entry_class.find(id))[:html]
      assert_match(/<p>\S/, html, "#{id} should render paragraphs with content")
    end
  end

  # Astro's style guide exercises most of Markdown in one file, so it doubles
  # as a check that the pieces a reader would notice missing all survive.
  def test_the_markdown_style_guide_keeps_its_structure
    result = convert(load_generated_entry_class.find("markdown-style-guide"))
    html = result[:html]

    (1..6).each { |level| assert_match(/<h#{level} id="h#{level}">H#{level}<\/h#{level}>/, html) }
    assert_includes result[:headings], { depth: 2, slug: "headings", text: "Headings" }
    assert_match(%r{<blockquote>\s*<p>Tiam}, html)
    assert_includes html, "<table>"
    assert_match(/<pre class="astro-code/, html)
    assert_includes html, "andromeda-asset:", "the relative image should be published, not left dangling"
  end

  private

  def convert(entry)
    Andromeda::Pipeline.new(store: Andromeda::Check::NullStore.new, mode: :development).convert(entry)
  end

  def run_generator
    Dir.chdir(@app) do
      generator = Andromeda::Generators::ImportAstroGenerator.new([ASTRO_PROJECT], [], destination_root: @app)
      capture_io { generator.invoke_all }
    end
  end

  # The generated file is plain Ruby, so loading it is the honest way to prove
  # the generator wrote something that works. It is evaluated inside a throwaway
  # module because another test suite defines its own Content::Blog, and two
  # `class Blog` bodies in one namespace would merge their schemas.
  def load_generated_entry_class
    source = File.read(File.join(@app, "app/models/content/blog.rb"))
                 .sub('base: "app/content/blog"', %(base: "#{@app}/app/content/blog"))
    namespace = Module.new
    namespace.module_eval(source, File.join(@app, "app/models/content/blog.rb"))
    namespace.const_get(:Content).const_get(:Blog)
  end
end
