# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/andromeda/collection/collection_generator"
require "fileutils"

module Generators
  class CollectionGeneratorTest < Rails::Generators::TestCase
    tests Andromeda::Generators::CollectionGenerator
    destination File.expand_path("../../tmp/generators/collection", __dir__)
    setup :prepare_destination
    # A real host app always has config/routes.rb by the time it runs a
    # generator; the generator's `route` step needs one to inject into.
    setup do
      FileUtils.mkdir_p(File.join(destination_root, "config"))
      File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
    end

    test "default invocation with no fields" do
      run_generator ["posts"]

      assert_file "app/models/content/post.rb" do |content|
        assert_match(/class Post < Andromeda::Entry/, content)
        assert_match(%r{collection :posts, base: "app/content/posts", pattern: "\*\*/\*\.\{md,mdx\}"}, content)
      end
      assert_file "app/controllers/posts_controller.rb" do |content|
        assert_match(/@entries = Content::Post\.all/, content)
        assert_match(/@entry = Content::Post\.find\(params\[:slug\]\)/, content)
      end
      assert_file "app/views/posts/index.html.erb", /andromeda_content|link_to entry\.id/
      assert_file "app/views/posts/show.html.erb", /andromeda_content @entry/
      assert_file "config/routes.rb", /resources :posts, only: %i\[index show\], param: :slug/
      assert_file "app/content/posts/hello-world.md"
    end

    test "an attribute of each supported type produces the matching declaration and frontmatter" do
      run_generator %w[
        events title:string starts_on:date starts_at:datetime featured:boolean
        priority:integer tags:array cover:image author:reference:authors
      ]

      assert_file "app/models/content/event.rb" do |content|
        assert_match(/attribute :title, :string$/, content)
        assert_match(/attribute :starts_on, :date$/, content)
        assert_match(/attribute :starts_at, :datetime$/, content)
        assert_match(/attribute :featured, :boolean, default: false$/, content)
        assert_match(/attribute :priority, :integer$/, content)
        assert_match(/attribute :tags, :array, of: :string, default: \[\]$/, content)
        assert_match(/attribute :cover, :image$/, content)
        assert_match(/attribute :author, :reference, collection: :authors$/, content)
      end

      assert_file "app/content/events/hello-world.md" do |content|
        assert_match(/^title: Hello World$/, content)
        assert_match(/^featured: false$/, content)
        assert_match(/^priority: 1$/, content)
        assert_match(/^tags: \[example\]$/, content)
        assert_match(/^cover: cover\.png$/, content)
        assert_match(/^author: example$/, content)
      end
      # The :image attribute needs a real file for Schema#coerce_image to
      # accept -- the generator creates an empty placeholder for it.
      assert_file "app/content/events/cover.png"
    end

    test "a reference field without an explicit collection guesses the pluralized field name" do
      run_generator ["posts", "author:reference"]

      assert_file "app/models/content/post.rb", /attribute :author, :reference, collection: :authors$/
    end

    test "an unrecognized type defaults to string" do
      run_generator ["posts", "title:nonsense"]

      assert_file "app/models/content/post.rb", /attribute :title, :string$/
    end

    test "a field with no :type defaults to string" do
      run_generator ["posts", "title"]

      assert_file "app/models/content/post.rb", /attribute :title, :string$/
    end

    test "pluralized name: `posts` produces Content::Post" do
      run_generator ["posts"]

      assert_file "app/models/content/post.rb", /class Post < Andromeda::Entry/
      assert_file "app/controllers/posts_controller.rb"
      assert_file "app/views/posts/index.html.erb"
      assert_file "app/content/posts/hello-world.md"
    end

    test "a name that is already singular keeps its own singular form" do
      run_generator ["blog"]

      assert_file "app/models/content/blog.rb", /class Blog < Andromeda::Entry/
      assert_file "app/controllers/blog_controller.rb"
      # The route/controller/content directory follow the given name as-is,
      # not a pluralized form.
      assert_file "config/routes.rb", /resources :blog,/
      assert_file "app/content/blog/hello-world.md"
    end

    test "running twice does not duplicate the route" do
      run_generator ["posts"]
      run_generator ["posts", "--force"]

      assert_file "config/routes.rb" do |content|
        assert_equal 1, content.scan("resources :posts").size
      end
    end

    test "the first-declared :string attribute is used as the title in the views and controller order" do
      run_generator ["posts", "headline:string", "pub_date:date"]

      assert_file "app/views/posts/show.html.erb", /@entry\.headline/
      assert_file "app/controllers/posts_controller.rb", /order\(pub_date: :desc\)/
    end

    # Proves the generated files are not just plausible-looking strings: the
    # model and controller must actually be valid Ruby, and the starter
    # content file must actually satisfy the schema the generator wrote for
    # it, end to end through the real Loader.
    test "the generated model parses and the starter content passes the generated schema" do
      run_generator %w[
        articles title:string pub_date:date draft:boolean tags:array cover:image writer:reference:writers
      ]

      model_path = File.join(destination_root, "app/models/content/article.rb")
      controller_path = File.join(destination_root, "app/controllers/articles_controller.rb")

      # RubyVM::InstructionSequence.compile raises SyntaxError on anything
      # that isn't parseable Ruby, without executing a single line of it.
      RubyVM::InstructionSequence.compile(File.read(model_path))
      RubyVM::InstructionSequence.compile(File.read(controller_path))

      # `load` (not `require`) so re-running this test in the same process
      # (or another test defining its own `Content::Article`) never sees a
      # stale, already-loaded constant.
      load model_path

      # Andromeda::Entry.collection resolves a relative `base:` against
      # Rails.root when Rails is loaded (true for this whole suite once
      # test/components_test.rb boots test/dummy) or Dir.pwd otherwise --
      # neither is the generator's own tmp destination, so the Loader is
      # driven directly at the generated content directory instead of going
      # through Content::Article.all's own base_dir resolution.
      loader = Andromeda::Loader.new(
        entry_class: Content::Article,
        base: File.join(destination_root, "app/content/articles"),
        pattern: Content::Article.pattern,
        schema: Content::Article.schema
      )
      entries = loader.load
      assert_equal 1, entries.size

      entry = entries.first
      assert_equal "Hello World", entry.data[:title]
      assert_equal false, entry.data[:draft]
      assert_equal ["example"], entry.data[:tags]
      assert_kind_of Andromeda::Image, entry.data[:cover]
      assert_kind_of Andromeda::Reference, entry.data[:writer]
      assert_equal :writers, entry.data[:writer].collection
    end
  end
end
