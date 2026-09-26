# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/andromeda/import_astro/import_astro_generator"

module Generators
  class ImportAstroGeneratorTest < Rails::Generators::TestCase
    tests Andromeda::Generators::ImportAstroGenerator
    destination File.expand_path("../../tmp/generators/import_astro", __dir__)
    setup :prepare_destination

    FIXTURE_PROJECT = File.expand_path("../fixtures/astro_project", __dir__)

    def run_import(extra_args = [])
      run_generator [FIXTURE_PROJECT, *extra_args]
    end

    test "copies content files, rewriting frontmatter keys to snake_case and leaving the body untouched" do
      run_import

      assert_file "app/content/blog/hello-world.md" do |content|
        assert_match(/^title: Hello World$/, content)
        assert_match(/^subtitle: Greetings$/, content)
        assert_match(/^pub_date: 2024-01-01$/, content)
        assert_match(/^hero_image: \.\/cover\.jpg$/, content)
        assert_match(/^draft: false$/, content)
        assert_match(/^views: 10$/, content)
        assert_match(/^category: tech$/, content)
        assert_match(/^tags: \[rails, astro\]$/, content)
        assert_match(/^author: jane$/, content)
        assert_no_match(/pubDate|heroImage/, content)
        # The body is untouched byte-for-byte, save for the rewritten keys above it.
        assert_match(/# Hello World\n\nWelcome to the migrated blog\.\n\z/, content)
      end
    end

    test "copies a sibling asset colocated with a content file byte-for-byte" do
      run_import

      assert_file "app/content/blog/cover.jpg" do |content|
        assert_equal File.binread(File.join(FIXTURE_PROJECT, "src/content/blog/cover.jpg")), content
      end
    end

    test "copies src/assets into app/assets byte-for-byte, preserving subdirectories" do
      run_import

      assert_file "app/assets/logo.svg" do |content|
        assert_equal File.binread(File.join(FIXTURE_PROJECT, "src/assets/logo.svg")), content
      end
      assert_file "app/assets/fonts/regular.woff" do |content|
        assert_equal File.binread(File.join(FIXTURE_PROJECT, "src/assets/fonts/regular.woff")), content
      end
    end

    test "rewrites MDX default-import component statements to the content_components partial path" do
      run_import

      assert_file "app/content/blog/second-post.mdx" do |content|
        assert_match(%r{^import Callout from 'content_components/callout';$}, content)
        assert_match(%r{^import Badge from 'content_components/badge';$}, content)
        assert_no_match(/components\/Callout\.astro/, content)
        # Tags, body Markdown and the body image reference are untouched.
        assert_match(/<Callout type="tip">/, content)
        assert_match(/<Badge label="new" \/>/, content)
        assert_match(%r{!\[Cover photo\]\(\./cover\.jpg\)}, content)
      end
    end

    test "generates one entry class per collection with attribute lines matching the Zod schema" do
      run_import

      assert_file "app/models/content/blog.rb" do |content|
        assert_match(/class Blog < Andromeda::Entry/, content)
        assert_match(%r{collection :blog, base: "app/content/blog", pattern: "\*\*/\*\.\{md,mdx\}"}, content)

        assert_match(/attribute :title, :string, required: true$/, content)
        assert_match(/attribute :description, :string$/, content)
        assert_match(/attribute :pub_date, :date, required: true$/, content)
        assert_match(/attribute :updated_date, :date$/, content)
        assert_match(/attribute :draft, :boolean, default: false$/, content)
        assert_match(/attribute :category, :enum, values: \["tech", "life"\], default: 'tech'$/, content)
        assert_match(/attribute :tags, :array, of: :string, default: \[\]$/, content)
        assert_match(/attribute :hero_image, :image$/, content)
        assert_match(/attribute :author, :reference, collection: :authors, required: true$/, content)

        # `extra: z.custom(...)` cannot be mapped -- it must show up as a
        # commented-out TODO, never silently vanish.
        assert_match(/# TODO: unsupported schema for `extra`.*z\.custom/, content)
        assert_match(/# attribute :extra, :string/, content)
      end
    end

    test "prefers the generated JSON Schema for required-ness and numeric precision" do
      run_import

      assert_file "app/models/content/blog.rb" do |content|
        # `views` is `z.number().default(0)` (naively :float), but the
        # fixture's blog.schema.json marks it `"type": "integer"`.
        assert_match(/attribute :views, :integer, default: 0$/, content)

        # `subtitle` has no `.optional()`/`.default()` in content.config.ts
        # (naively required), but blog.schema.json's `required` list omits
        # it -- the JSON Schema wins.
        assert_match(/^\s*attribute :subtitle, :string$/, content)
        refute_match(/attribute :subtitle, :string, required: true/, content)
      end
    end

    test "generates a component stub only for a component with no existing partial" do
      FileUtils.mkdir_p(File.join(destination_root, "app/views/content_components"))
      File.write(File.join(destination_root, "app/views/content_components/_callout.html.erb"), "already here\n")

      run_import

      assert_file "app/views/content_components/_callout.html.erb", "already here\n"
      assert_file "app/views/content_components/_badge.html.erb" do |content|
        assert_match(/<%# MDX usage:/, content)
        assert_match(/<Badge label="\.\.\.">/, content)
        assert_match(/<%= content %>/, content)
      end
    end

    test "the migration report lists copies, rewrites, generated files and what still needs a human" do
      output = run_import

      assert_match(%r{app/content/blog/hello-world\.md}, output)
      assert_match(/Frontmatter keys renamed to snake_case/, output)
      assert_match(/pubDate -> pub_date/, output)
      assert_match(/MDX import statements rewritten/, output)
      assert_match(/Entry classes generated/, output)
      assert_match(/app\/models\/content\/blog\.rb/, output)
      assert_match(/Component stubs generated/, output)
      assert_match(/app\/views\/content_components\/_badge\.html\.erb/, output)
      assert_match(/Collections that used Astro's generated JSON Schema/, output)
      assert_match(/blog/, output)
      assert_match(/Needs a human/, output)
      assert_match(/Unmapped schema fields/, output)
      assert_match(/blog\.extra/, output)
    end

    test "--dry-run prints the same kind of report but writes nothing" do
      output = run_import(["--dry-run"])

      assert_match(/dry run/, output)
      assert_match(/Frontmatter keys renamed to snake_case/, output)
      assert_match(/Entry classes generated/, output)

      assert_no_file "app/content/blog/hello-world.md"
      assert_no_file "app/content/blog/second-post.mdx"
      assert_no_file "app/assets/logo.svg"
      assert_no_file "app/models/content/blog.rb"
      assert_no_file "app/views/content_components/_callout.html.erb"
      assert_no_file "app/views/content_components/_badge.html.erb"
    end

    # Regression: a `//` comment directly above a field (as Astro's own
    # blog example writes above `pubDate`) must not fuse onto the next
    # field's key -- found by running this generator against the real
    # `withastro/astro` `examples/blog` template during development.
    test "a `//` comment above a schema field does not corrupt the next field's name" do
      source = <<~TS
        import { defineCollection } from 'astro:content';
        import { glob } from 'astro/loaders';
        import { z } from 'astro/zod';

        const blog = defineCollection({
        	loader: glob({ base: './src/content/blog', pattern: '**/*.md' }),
        	schema: z.object({
        		title: z.string(),
        		// Transform string to Date object
        		pubDate: z.coerce.date(),
        	}),
        });

        export const collections = { blog };
      TS

      collections = Andromeda::Generators::ImportAstro::ContentConfigConverter.parse(source, astro_root: "/tmp")
      pub_date = collections.first.attributes.find { |a| a.name == "pubDate" }

      refute_nil pub_date, "expected a `pubDate` attribute, not one fused with the preceding comment"
      assert_equal :date, pub_date.ruby_type
    end

    # End to end: the generated entry class must actually be loadable Ruby,
    # and the migrated content must satisfy the schema the generator wrote
    # for it, through the real Loader -- not just look right as text.
    test "the generated entry class loads and the migrated content validates through the real Loader" do
      run_import

      model_path = File.join(destination_root, "app/models/content/blog.rb")
      RubyVM::InstructionSequence.compile(File.read(model_path))
      load model_path

      loader = Andromeda::Loader.new(
        entry_class: Content::Blog,
        base: File.join(destination_root, "app/content/blog"),
        pattern: Content::Blog.pattern,
        schema: Content::Blog.schema
      )
      entries = loader.load
      assert_equal 2, entries.size

      hello = entries.find { |e| e.id == "hello-world" }
      assert_equal "Hello World", hello.data[:title]
      assert_equal false, hello.data[:draft]
      assert_equal 10, hello.data[:views]
      assert_equal ["rails", "astro"], hello.data[:tags]
      assert_kind_of Andromeda::Image, hello.data[:hero_image]
      assert_kind_of Andromeda::Reference, hello.data[:author]
      assert_equal :authors, hello.data[:author].collection

      second = entries.find { |e| e.id == "second-post" }
      assert_equal "life", second.data[:category]
    end
  end
end
