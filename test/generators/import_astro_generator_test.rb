# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "tmpdir"
require "ripper"
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

    # Runs the import against a throwaway Astro project whose
    # `content.config.ts` declares `collections_source` (one `blog`
    # collection with a single Markdown file).
    def run_import_with_config(collections_source)
      Dir.mktmpdir do |astro_root|
        FileUtils.mkdir_p(File.join(astro_root, "src/content/blog"))
        File.write(File.join(astro_root, "src/content/blog/post.md"), "---\ntitle: Post\n---\n")
        File.write(File.join(astro_root, "src/content.config.ts"), <<~TS)
          import { defineCollection } from 'astro:content';
          import { glob } from 'astro/loaders';

          #{collections_source}
          export const collections = { blog };
        TS

        run_generator [astro_root]
      end
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
        assert_match(/attribute :category, :enum, values: \["tech", "life"\], default: "tech"$/, content)
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

    test "an array pattern keeps its first non-exclusion element and flags the dropped exclusions" do
      output = run_import_with_config(<<~TS)
        const blog = defineCollection({
          loader: glob({
            base: './src/content/blog',
            pattern: ['!drafts/**', '**/*.md', '**/*.mdx'],
          }),
        });
      TS

      assert_match(/blog: exclusions `!drafts\/\*\*` from pattern array \[ ?'!drafts\/\*\*', '\*\*\/\*\.md', '\*\*\/\*\.mdx',? ?\] are not applied/, output)
      assert_match(/blog: patterns `\*\*\/\*\.mdx` from pattern array .* were dropped \(only `\*\*\/\*\.md` was kept\)/, output)

      assert_file "app/models/content/blog.rb" do |content|
        assert_match(/^\s*# TODO: exclusions `!drafts.*-- fix `pattern` by hand\.\n\s*# TODO: patterns `\*\*\/\*\.mdx`.*\n\s*collection :blog/, content)
        assert_match(%r{collection :blog, base: "app/content/blog", pattern: "\*\*/\*\.md"$}, content)
      end
    end

    test "an array pattern without exclusions notes only the dropped patterns" do
      output = run_import_with_config(<<~TS)
        const blog = defineCollection({
          loader: glob({ base: './src/content/blog', pattern: ['**/*.md', '**/*.mdx'] }),
        });
      TS

      assert_match(/blog: patterns `\*\*\/\*\.mdx` from pattern array .* were dropped/, output)
      assert_no_match(/exclusions/, output)
      assert_file "app/models/content/blog.rb" do |content|
        assert_match(%r{collection :blog, base: "app/content/blog", pattern: "\*\*/\*\.md"$}, content)
      end
    end

    test "a one-element array pattern adds no note" do
      output = run_import_with_config(<<~TS)
        const blog = defineCollection({
          loader: glob({ base: './src/content/blog', pattern: ['**/*.md'] }),
        });
      TS

      assert_no_match(/Notes:/, output)
      assert_file "app/models/content/blog.rb" do |content|
        assert_no_match(/# TODO/, content)
        assert_match(%r{collection :blog, base: "app/content/blog", pattern: "\*\*/\*\.md"$}, content)
      end
    end

    test "an extglob pattern is flagged as matching nothing under Ruby's glob" do
      output = run_import_with_config(<<~TS)
        const blog = defineCollection({
          loader: glob({ base: './src/content/blog', pattern: '!(drafts)/**/*.md' }),
        });
      TS

      assert_match(/blog: pattern `!\(drafts\)\/\*\*\/\*\.md` uses extglob syntax/, output)
    end

    test "a plain string pattern adds no note" do
      output = run_import_with_config(<<~TS)
        const blog = defineCollection({
          loader: glob({ base: './src/content/blog', pattern: '**/*.md' }),
        });
      TS

      assert_no_match(/Notes:/, output)
      assert_file "app/models/content/blog.rb" do |content|
        assert_no_match(/# TODO/, content)
      end
    end

    # A malicious Astro theme controls content.config.ts. Every place its
    # text reaches the generated class -- `.default()`, `pattern`,
    # `reference()`, a quoted field name, and the TODO/NOTE comments -- must
    # come out as data (a string, a symbol, a comment), never as code that
    # runs when Rails eager-loads the model.
    test "nothing in content.config.ts becomes Ruby code in the generated entry class" do
      run_import_with_config(<<~'TS')
        const blog = defineCollection({
          loader: glob({ base: './src/content/blog', pattern: '**/*#{pwned_pattern}.md' }),
          schema: z.object({
            title: z.string().default("#{pwned_default}"),
            tags: z.array(z.string()).default([`pwned_backtick`]),
            calls: z.array(z.string()).default([pwned_call()]),
            author: reference('authors; pwned_reference #'),
            "key; pwned_key #": z.string(),
            notes: z.array(z.string()
        pwned_note #),
          }),
        });
      TS

      assert_file "app/models/content/blog.rb" do |content|
        RubyVM::InstructionSequence.compile(content)

        tokens = Ripper.lex(content)
        executable = tokens.select { |(_, type, token)| %i[on_ident on_const].include?(type) && token.include?("pwned") }
        assert_empty executable, "imported text became Ruby code:\n#{content}"
        assert_empty tokens.select { |(_, type, _)| %i[on_embexpr_beg on_backtick].include?(type) },
                     "generated class has interpolation or a command string:\n#{content}"

        # The JS string is still carried over -- as the literal text it is.
        assert_includes content, 'attribute :title, :string, default: "\#{pwned_default}"'
        assert_includes content, 'pattern: "**/*\#{pwned_pattern}.md"'
        assert_includes content, 'collection: :"authors; pwned_reference #"'
        # Defaults that are not plain literals are dropped, not copied.
        assert_match(/^\s*attribute :tags, :array, of: :string$/, content)
        assert_match(/^\s*attribute :calls, :array, of: :string$/, content)
        # A field name that is not an identifier becomes a TODO.
        assert_match(/^\s*# NOTE: field name `key; pwned_key #` is not a valid attribute name$/, content)
      end
    end

    # Without content.config.ts every directory under src/content/ becomes
    # a collection, and its name goes into the generated class name and
    # `collection :name` -- so a directory name must never become code.
    test "without content.config.ts, a directory whose name is not an identifier is skipped" do
      output = Dir.mktmpdir do |astro_root|
        ["blog", "blog-posts", "x; pwned_dir #"].each do |name|
          FileUtils.mkdir_p(File.join(astro_root, "src/content", name))
          File.write(File.join(astro_root, "src/content", name, "post.md"), "---\ntitle: Post\n---\n")
        end

        run_generator [astro_root]
      end

      assert_file "app/models/content/blog.rb"
      assert_file "app/content/blog/post.md"
      assert_equal ["blog.rb"], Dir.children(File.join(destination_root, "app/models/content"))
      assert_equal ["blog"], Dir.children(File.join(destination_root, "app/content"))
      assert_match(/^\s*blog-posts: skipped -- a collection name must be/, output)
      assert_match(/^\s*x; pwned_dir #: skipped -- a collection name must be/, output)
    end

    test "a `false` default is kept, not mistaken for no default" do
      run_import_with_config(<<~TS)
        const blog = defineCollection({
          loader: glob({ base: './src/content/blog', pattern: '**/*.md' }),
          schema: z.object({
            featured: z.boolean().default(false),
            ratio: z.number().default(-1.5),
            labels: z.array(z.string()).default(['a', "it's",]),
          }),
        });
      TS

      assert_file "app/models/content/blog.rb" do |content|
        assert_match(/^\s*attribute :featured, :boolean, default: false$/, content)
        assert_match(/^\s*attribute :ratio, :float, default: -1\.5$/, content)
        assert_match(/^\s*attribute :labels, :array, of: :string, default: \["a", "it's"\]$/, content)
      end
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

    # Builds a throwaway Astro project (with `blog` content and a config
    # declaring `blog`) next to a separate "outside" directory holding a
    # secret file, yields both, and returns the generator's output.
    def with_project_and_outside(config_source: nil)
      Dir.mktmpdir do |dir|
        astro_root = File.join(dir, "astro")
        outside = File.join(dir, "outside")
        FileUtils.mkdir_p([File.join(astro_root, "src/content/blog"), outside])
        File.write(File.join(outside, "secret.md"), "---\ntitle: Secret\n---\n")
        File.write(File.join(astro_root, "src/content/blog/post.md"), "---\ntitle: Post\n---\n")
        File.write(File.join(astro_root, "src/content.config.ts"), config_source) if config_source
        yield astro_root, outside
      end
    end

    def blog_config(loader)
      <<~TS
        import { defineCollection } from 'astro:content';
        import { glob } from 'astro/loaders';
        const blog = defineCollection({ loader: #{loader} });
        export const collections = { blog };
      TS
    end

    test "a glob base outside the Astro project is not copied and is reported" do
      with_project_and_outside do |astro_root, outside|
        ["'#{outside}'", "'../outside'"].each do |base|
          File.write(File.join(astro_root, "src/content.config.ts"),
                     blog_config("glob({ pattern: '**/*.md', base: #{base} })"))
          output = run_generator [astro_root]

          assert_no_file "app/content/blog/secret.md"
          assert_match(/not copied -- it resolves to a location outside the Astro project/, output)
        end
      end
    end

    # A symlink inside the project can point anywhere on the machine; only
    # files whose real path stays inside the project may be copied.
    test "symlinks to files outside the Astro project are not copied and are reported" do
      with_project_and_outside do |astro_root, outside|
        FileUtils.mkdir_p(File.join(astro_root, "src/assets"))
        File.symlink(File.join(outside, "secret.md"), File.join(astro_root, "src/content/blog/leak.md"))
        File.symlink(File.join(outside, "secret.md"), File.join(astro_root, "src/assets/leak.txt"))

        output = run_generator [astro_root]

        assert_no_file "app/content/blog/leak.md"
        assert_no_file "app/assets/leak.txt"
        assert_file "app/content/blog/post.md"
        assert_match(%r{src/content/blog/leak\.md: not copied -- it resolves to a location outside}, output)
        assert_match(%r{src/assets/leak\.txt: not copied -- it resolves to a location outside}, output)
      end
    end

    test "a symlink to another file inside the Astro project is still copied" do
      with_project_and_outside do |astro_root, _outside|
        File.symlink(File.join(astro_root, "src/content/blog/post.md"), File.join(astro_root, "src/content/blog/alias.md"))

        run_generator [astro_root]

        assert_file "app/content/blog/alias.md", /title: Post/
      end
    end

    # `BEGIN`/`END` are reserved words and `_` singularizes to nothing
    # usable, so they cannot become class names in the generated code.
    test "collections whose names cannot be valid class names are skipped while valid ones are generated" do
      config = <<~TS
        import { defineCollection } from 'astro:content';
        import { glob } from 'astro/loaders';
        const BEGIN = defineCollection({ loader: glob({ pattern: '**/*.md', base: './src/content/BEGIN' }) });
        const _ = defineCollection({ loader: glob({ pattern: '**/*.md', base: './src/content/_' }) });
        const blog = defineCollection({ loader: glob({ pattern: '**/*.md', base: './src/content/blog' }) });
        export const collections = { blog };
      TS

      with_project_and_outside(config_source: config) do |astro_root, _outside|
        output = run_generator [astro_root]

        assert_file "app/models/content/blog.rb"
        assert_no_file "app/models/content/begin.rb"
        assert_no_file "app/models/content/_.rb"
        assert_match(/BEGIN: skipped -- a collection name must be/, output)
        assert_match(/_: skipped -- a collection name must be/, output)
      end
    end

    def write_mdx_project(astro_root, mdx)
      FileUtils.mkdir_p(File.join(astro_root, "src/content/blog"))
      File.write(File.join(astro_root, "src/content/blog/post.mdx"), "---\ntitle: Post\n---\n\n#{mdx}\n")
    end

    # Thor's `invoke` runs a generator class once per run, so only the first
    # component used ever got a stub.
    test "generates a stub for every component used in an MDX file and none for lowercase tags" do
      Dir.mktmpdir do |astro_root|
        write_mdx_project(astro_root, "<Alpha />\n\n<Beta title=\"x\" />\n\n<div>plain</div>")

        run_generator [astro_root]

        assert_file "app/views/content_components/_alpha.html.erb"
        assert_file "app/views/content_components/_beta.html.erb"
        assert_no_file "app/views/content_components/_div.html.erb"
      end
    end

    test "a component tag with an invalid name is reported without aborting the import" do
      Dir.mktmpdir do |astro_root|
        write_mdx_project(astro_root, "<Foo-bar />\n\n<Alpha />")

        output = run_generator [astro_root]

        assert_match(/Foo-bar>: no partial stub generated/, output)
        assert_file "app/views/content_components/_alpha.html.erb"
        assert_file "app/content/blog/post.mdx"
      end
    end

    test "a content.config.ts that is not valid UTF-8 stops the import before anything is written" do
      with_project_and_outside do |astro_root, _outside|
        File.binwrite(File.join(astro_root, "src/content.config.ts"), "const blog = \xFF defineCollection({});\n")

        # Thor::Error is rescued by `start` and printed, not re-raised.
        stderr = capture(:stderr) { run_generator [astro_root] }

        assert_match(/content\.config\.ts is not valid UTF-8/, stderr)
        assert_no_directory "app"
      end
    end

    test "a content file that is not valid UTF-8 is copied unchanged and the import continues" do
      with_project_and_outside do |astro_root, _outside|
        bytes = "---\ntitle: \xFF\n---\nbody\n".b
        File.binwrite(File.join(astro_root, "src/content/blog/bad.md"), bytes)

        output = run_generator [astro_root]

        assert_equal bytes, File.binread(File.join(destination_root, "app/content/blog/bad.md"))
        assert_match(/bad\.md: not valid UTF-8 -- copied unchanged/, output)
        assert_file "app/content/blog/post.md"
        assert_file "app/models/content/blog.rb"
      end
    end

    # `properties` should be a Hash; anything else must be ignored, not raise.
    test "a malformed generated JSON Schema does not break numeric precision lookup" do
      with_project_and_outside(config_source: <<~TS) do |astro_root, _outside|
        import { defineCollection, z } from 'astro:content';
        import { glob } from 'astro/loaders';
        const blog = defineCollection({
          loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
          schema: z.object({ views: z.number() })
        });
        export const collections = { blog };
      TS
        FileUtils.mkdir_p(File.join(astro_root, ".astro/collections"))
        File.write(File.join(astro_root, ".astro/collections/blog.schema.json"), '{"properties": [1]}')

        run_generator [astro_root]

        assert_file "app/models/content/blog.rb", /attribute :views, :float/
      end
    end

    # A file name comes from the imported project; an ANSI escape in it must
    # not reach the terminal raw.
    test "control characters in reported names are escaped in the output" do
      with_project_and_outside do |astro_root, _outside|
        File.write(File.join(astro_root, "src/content/blog/a\e[31mb.md"), "---\ntitle: X\n---\n")

        output = run_generator [astro_root]

        # Thor's own `create` status lines echo the path as-is; the migration
        # report (everything after the summary heading) is what is escaped.
        report = output[/Astro import complete.*/m]
        assert_includes report, "\\e[31m"
        refute_includes report, "\e"
      end
    end
  end
end
