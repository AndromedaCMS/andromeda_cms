# frozen_string_literal: true

require "test_helper"
require "generators/andromeda/import_astro/content_config_converter"

module Generators
  class ImportAstroContentConfigConverterTest < ActiveSupport::TestCase
    Converter = Andromeda::Generators::ImportAstro::ContentConfigConverter

    # @return [Array(Boolean, Object)] what `literal_default` makes of the
    #   argument of `.default(...)`.
    def default_of(text)
      Converter.literal_default(text)
    end

    test "scalar defaults become Ruby values" do
      assert_equal [true, true], default_of("true")
      assert_equal [true, false], default_of("false")
      assert_equal [true, 0], default_of("0")
      assert_equal [true, -12], default_of("-12")
      assert_equal [true, 1.5], default_of(" 1.5 ")
      assert_equal [true, "tech"], default_of("'tech'")
      assert_equal [true, "tech"], default_of('"tech"')
      assert_equal [true, ""], default_of("''")
    end

    test "JS string escapes are decoded the way JS reads them" do
      assert_equal [true, "it's"], default_of("'it\\'s'")
      assert_equal [true, 'say "hi"'], default_of('"say \\"hi\\""')
      assert_equal [true, "a\\b"], default_of("'a\\\\b'")
      assert_equal [true, "a\nb\tc"], default_of("'a\\nb\\tc'")
    end

    test "an array of scalars becomes a Ruby array" do
      assert_equal [true, []], default_of("[]")
      assert_equal [true, ["a", "b"]], default_of("['a', \"b\",]")
      assert_equal [true, [1, 2.5, true]], default_of("[1, 2.5, true]")
    end

    # `"#{...}"` is an ordinary string in JS, so it is kept -- as the literal
    # characters, which the generator then writes back with `inspect`.
    test "a JS string that looks like Ruby interpolation is kept as plain text" do
      assert_equal [true, "\#{system('id')}"], default_of("\"\#{system('id')}\"")
    end

    test "anything that is not a plain literal is dropped" do
      [
        "[`id`]",              # template literal / Ruby command string
        "[system('id')]",      # a call inside an array
        "someVariable",
        "new Date()",
        "() => 'x'",
        "[[1]]",               # nested arrays
        "'a\\q'",              # an escape outside the decoded set
        "'a\\01'",             # a legacy octal escape
        "0123",                # a legacy octal number
        "#{"9" * 400}.0",      # too large for a Float (would be Infinity)
        "'a' + 'b'",
        "'a\nb'",              # a raw newline inside the string
        "'unterminated",
        "\"mixed'"
      ].each do |text|
        assert_equal [false, nil], default_of(text), "expected #{text.inspect} to be dropped"
      end
    end

    test "a field with an unparseable default is optional and has no default" do
      attribute = Converter.build_attribute("tags", "z.array(z.string()).default([`id`])")

      assert_equal :array, attribute.ruby_type
      assert_equal false, attribute.required
      refute attribute.default?
    end

    test "a field with a `false` default reports that it has a default" do
      attribute = Converter.build_attribute("draft", "z.boolean().default(false)")

      assert attribute.default?
      assert_equal false, attribute.default
    end

    test "a field name that is not an identifier is left unsupported with a note" do
      attribute = Converter.build_attribute("a; system('id') #", "z.string()")

      assert attribute.unsupported?
      assert_match(/field name `a; system\('id'\) #` is not a valid attribute name/, attribute.note)
    end

    test "camelCase and kebab-case field names are still accepted" do
      refute Converter.build_attribute("pubDate", "z.coerce.date()").unsupported?
      refute Converter.build_attribute("hero-image", "z.string()").unsupported?
      refute Converter.build_attribute("_private", "z.string()").unsupported?
    end

    # Decoded by hand rather than by the Ruby parser, so each escape JS
    # understands has to be pinned down.
    test "JS unicode, hex, slash and NUL escapes are decoded" do
      assert_equal [true, "café"], default_of("'caf\\u00e9'")
      assert_equal [true, "😀"], default_of("'\\u{1F600}'")
      assert_equal [true, "A"], default_of("'\\x41'")
      assert_equal [true, "a/b"], default_of("'a\\/b'")
      assert_equal [true, "a\u0000"], default_of("'a\\0'")
    end

    # A lone surrogate half has no UTF-8 encoding, so it is dropped rather
    # than raising or producing an invalid string.
    test "a lone surrogate escape makes the default unparseable" do
      assert_equal [false, nil], default_of("'\\uD83D'")
    end

    test "a default that is not a plain literal adds a note to the attribute" do
      attribute = Converter.build_attribute("created", "z.date().default(() => new Date())")

      refute attribute.default?
      assert_includes attribute.note, "is not a plain literal and was not carried over"
    end

    test "the dropped-default note is joined to an existing note with a semicolon" do
      attribute = Converter.build_attribute("tags", "z.array(z.string().or(z.number())).default(() => [])")

      assert_match(/\S; default `.*` is not a plain literal and was not carried over/, attribute.note)
    end

    test "a glob pattern that escapes the collection directory is replaced and noted" do
      ["'../../config/*'", "'/etc/*'", "'~/x/*.md'", "['../x/*.md', '**/*.md']"].each do |pattern|
        collection = parse_blog("glob({ pattern: #{pattern}, base: './src/content/blog' })")

        assert_equal "**/*.{md,mdx}", collection.pattern, "pattern #{pattern}"
        assert collection.notes.any? { |note| note.include?("reaches outside the collection directory") },
               "expected a note for #{pattern}, got #{collection.notes.inspect}"
      end
    end

    test "a pattern that stays inside the collection directory is unchanged" do
      assert_equal "**/*.md", parse_blog("glob({ pattern: '**/*.md', base: './src/content/blog' })").pattern
      assert_equal "posts/**/*.md", parse_blog("glob({ pattern: 'posts/**/*.md', base: './src/content/blog' })").pattern
      refute parse_blog("glob({ pattern: '**/*.md', base: './src/content/blog' })").notes.any? { |n| n.include?("outside") }
    end

    # `index("const blog")` used to match inside `const blogPosts`, giving
    # `blog` the schema of `blogPosts`.
    test "parse gives each collection its own body when one name prefixes another" do
      source = <<~TS
        const blogPosts = defineCollection({
          loader: glob({ pattern: '**/*.md', base: './src/content/blogPosts' }),
          schema: z.object({ alpha: z.string() })
        });
        const blog = defineCollection({
          loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
          schema: z.object({ beta: z.number() })
        });
      TS

      collections = Converter.parse(source, astro_root: "/tmp").to_h { |c| [c.name, c] }

      assert_equal ["alpha"], collections["blogPosts"].attributes.map(&:name)
      assert_equal ["beta"], collections["blog"].attributes.map(&:name)
    end

    test "parse skips a defineCollection whose parenthesis never closes" do
      source = <<~TS
        const broken = defineCollection({ schema: z.object({ a: z.string() })
      TS

      assert_equal [], Converter.parse(source, astro_root: "/tmp")
    end

    def parse_blog(loader)
      source = "const blog = defineCollection({ loader: #{loader}, schema: z.object({}) });"
      Converter.parse(source, astro_root: "/tmp").first
    end
  end
end
