# frozen_string_literal: true

require "test_helper"

class FrontmatterTest < Minitest::Test
  # --- split -----------------------------------------------------------

  def test_split_with_no_frontmatter_returns_source_untouched
    source = "# Just a heading\n\nSome text.\n"

    assert_equal [nil, nil, source], Andromeda::Frontmatter.split(source)
  end

  def test_split_recognizes_yaml_fence
    _, format, = Andromeda::Frontmatter.split("---\ntitle: x\n---\nBody\n")

    assert_equal :yaml, format
  end

  def test_split_recognizes_toml_fence
    _, format, = Andromeda::Frontmatter.split("+++\ntitle = \"x\"\n+++\nBody\n")

    assert_equal :toml, format
  end

  def test_split_with_empty_frontmatter_block
    data, body = Andromeda::Frontmatter.parse("---\n---\n# Heading\n")

    assert_equal({}, data)
    assert_equal "\n\n# Heading\n", body
  end

  def test_thematic_break_in_body_is_not_treated_as_frontmatter
    source = "above\n\n---\n\nbelow\n"

    data, body = Andromeda::Frontmatter.parse(source)

    assert_equal({}, data)
    assert_equal source, body
  end

  def test_second_fence_after_real_frontmatter_is_left_alone_in_body
    source = "---\ntitle: x\n---\nabove\n\n---\n\nbelow\n"

    data, body = Andromeda::Frontmatter.parse(source)

    assert_equal({ "title" => "x" }, data)
    assert_includes body, "above\n\n---\n\nbelow\n"
  end

  def test_unterminated_frontmatter_block_is_treated_as_no_frontmatter
    source = "---\ntitle: x\nno closing fence here\n"

    data, body = Andromeda::Frontmatter.parse(source)

    assert_equal({}, data)
    assert_equal source, body
  end

  def test_dashes_with_nothing_after_are_not_frontmatter
    assert_equal [nil, nil, "---"], Andromeda::Frontmatter.split("---")
  end

  def test_quoted_string_containing_fence_delimiter_does_not_close_early
    source = %(---\ndescription: "See --- section for details"\n---\nBody\n)

    data, = Andromeda::Frontmatter.parse(source)

    assert_equal "See --- section for details", data["description"]
  end

  def test_leading_bom_is_tolerated
    source = "\uFEFF---\ntitle: x\n---\nHello\n"

    data, body = Andromeda::Frontmatter.parse(source)

    assert_equal({ "title" => "x" }, data)
    assert_includes body, "Hello\n"
  end

  def test_leading_blank_lines_before_fence_are_tolerated
    source = "\n\n---\ntitle: x\n---\nHello\n"

    data, = Andromeda::Frontmatter.parse(source)

    assert_equal({ "title" => "x" }, data)
  end

  def test_crlf_frontmatter_is_split_and_parsed
    source = "---\r\ntitle: x\r\n---\r\nHello\r\n"

    data, body = Andromeda::Frontmatter.parse(source)

    assert_equal({ "title" => "x" }, data)
    assert_includes body, "Hello\r\n"
  end

  # --- YAML scalars ------------------------------------------------------

  def test_yaml_strings_ints_floats_booleans_null_arrays_nested_maps
    source = <<~YAML
      ---
      name: Andromeda
      count: 3
      ratio: 1.5
      published: true
      tags:
        - ruby
        - rails
      meta:
        author: jane
        active: false
      ---
      Body
    YAML

    data, = Andromeda::Frontmatter.parse(source)

    assert_equal(
      {
        "name" => "Andromeda",
        "count" => 3,
        "ratio" => 1.5,
        "published" => true,
        "tags" => %w[ruby rails],
        "meta" => { "author" => "jane", "active" => false },
      },
      data
    )
  end

  def test_yaml_1_1_yes_no_style_scalars_stay_strings
    source = <<~YAML
      ---
      a: yes
      b: no
      c: on
      d: off
      e: y
      f: n
      g: Yes
      h: NO
      ---
      Body
    YAML

    data, = Andromeda::Frontmatter.parse(source)

    assert_equal(
      { "a" => "yes", "b" => "no", "c" => "on", "d" => "off", "e" => "y", "f" => "n", "g" => "Yes", "h" => "NO" },
      data
    )
  end

  def test_yaml_quoted_yes_stays_a_string
    data, = Andromeda::Frontmatter.parse(%(---\nflag: "yes"\n---\n))

    assert_equal "yes", data["flag"]
  end

  def test_yaml_real_booleans_still_work
    data, = Andromeda::Frontmatter.parse("---\na: true\nb: false\nc: True\nd: FALSE\n---\n")

    assert_equal({ "a" => true, "b" => false, "c" => true, "d" => false }, data)
  end

  def test_yaml_date_without_time_becomes_a_date
    data, = Andromeda::Frontmatter.parse("---\npub_date: 2026-09-22\n---\n")

    assert_instance_of Date, data["pub_date"]
    assert_equal Date.new(2026, 9, 22), data["pub_date"]
  end

  def test_yaml_timestamp_with_timezone_becomes_a_time
    data, = Andromeda::Frontmatter.parse("---\nts: 2026-09-22T10:00:00+09:00\n---\n")

    assert_instance_of Time, data["ts"]
    assert_equal 9 * 3600, data["ts"].utc_offset
  end

  def test_yaml_timestamp_without_timezone_becomes_a_time
    data, = Andromeda::Frontmatter.parse("---\nts: 2026-09-22 10:00:00\n---\n")

    assert_instance_of Time, data["ts"]
  end

  def test_yaml_anchors_and_aliases_are_resolved
    data, = Andromeda::Frontmatter.parse("---\nbase: &default foo\nother: *default\n---\n")

    assert_equal "foo", data["base"]
    assert_equal "foo", data["other"]
  end

  # --- TOML ----------------------------------------------------------------

  def test_toml_scalars_tables_and_arrays_of_tables
    source = <<~TOML
      +++
      title = "hi"
      published = true
      +++
      Body
    TOML

    data, = Andromeda::Frontmatter.parse(source)

    assert_equal({ "title" => "hi", "published" => true }, data)
  end

  def test_toml_tables_and_array_of_tables
    source = <<~TOML
      +++
      title = "hi"

      [meta]
      author = "jane"

      [[items]]
      x = 1

      [[items]]
      x = 2
      +++
      Body
    TOML

    data, = Andromeda::Frontmatter.parse(source)

    assert_equal("hi", data["title"])
    assert_equal({ "author" => "jane" }, data["meta"])
    assert_equal([{ "x" => 1 }, { "x" => 2 }], data["items"])
  end

  def test_toml_dates_become_date_and_time
    source = <<~TOML
      +++
      day = 2026-09-22
      moment = 2026-09-22T10:00:00Z
      local_moment = 2026-09-22T10:00:00
      +++
    TOML

    data, = Andromeda::Frontmatter.parse(source)

    assert_instance_of Date, data["day"]
    assert_equal Date.new(2026, 9, 22), data["day"]
    assert_instance_of Time, data["moment"]
    assert_instance_of Time, data["local_moment"]
  end

  # --- errors ----------------------------------------------------------

  def test_malformed_yaml_raises_syntax_error_with_absolute_line_and_path
    source = <<~YAML
      ---
      title: [1, 2
      subtitle: 3
      ---
      Body
    YAML

    error = assert_raises(Andromeda::SyntaxError) do
      Andromeda::Frontmatter.parse(source, path: "app/content/blog/x.md")
    end

    assert_equal "app/content/blog/x.md", error.path
    assert_equal 3, error.line
    assert_kind_of Integer, error.column
    assert error.message.start_with?("app/content/blog/x.md:3:"),
           "expected path:line:... prefix, got: #{error.message}"
  end

  def test_malformed_yaml_without_path_still_reports_line
    # The unterminated `[` gives Psych nothing more to read before hitting
    # the closing fence, so it reports the error where it ran out of input --
    # the closing fence's own line (3) -- rather than the line the `[` is on.
    source = "---\ntitle: [1, 2\n---\n"

    error = assert_raises(Andromeda::SyntaxError) do
      Andromeda::Frontmatter.parse(source)
    end

    assert_nil error.path
    assert_equal 3, error.line
  end

  def test_malformed_toml_raises_syntax_error_with_absolute_line_and_path
    source = <<~TOML
      +++
      title = "hi"
      bad = [1, 2
      more = 3
      +++
      Body
    TOML

    error = assert_raises(Andromeda::SyntaxError) do
      Andromeda::Frontmatter.parse(source, path: "app/content/blog/x.md")
    end

    assert_equal "app/content/blog/x.md", error.path
    assert_equal 4, error.line
    assert_kind_of Integer, error.column
  end

  def test_syntax_errors_from_frontmatter_are_andromeda_errors
    assert_operator Andromeda::SyntaxError, :<, Andromeda::Error
  end

  # --- line preservation -----------------------------------------------

  def test_body_keeps_original_line_numbers_for_the_parser
    source = <<~MARKDOWN
      ---
      title: Hello
      tags:
        - a
        - b
      ---
      # Heading
    MARKDOWN

    _, body = Andromeda::Frontmatter.parse(source)
    tree = Andromeda::Parser.parse(body)
    heading = tree[:children].find { |node| node[:type] == "heading" }

    refute_nil heading
    assert_equal 7, heading[:position][:start][:line]
  end

  # --- no frontmatter --------------------------------------------------

  def test_parse_with_no_frontmatter_returns_empty_hash_and_original_body
    source = "# Just a heading\n"

    data, body = Andromeda::Frontmatter.parse(source)

    assert_equal({}, data)
    assert_equal source, body
  end

  # --- non_snake_case_keys ----------------------------------------------

  def test_non_snake_case_keys_flags_camel_case
    assert_equal ["pubDate"], Andromeda::Frontmatter.non_snake_case_keys({ "pubDate" => 1 })
  end

  def test_non_snake_case_keys_flags_kebab_case
    assert_equal ["hero-image"], Andromeda::Frontmatter.non_snake_case_keys({ "hero-image" => 1 })
  end

  def test_non_snake_case_keys_flags_pascal_case
    assert_equal ["Title"], Andromeda::Frontmatter.non_snake_case_keys({ "Title" => 1 })
  end

  def test_non_snake_case_keys_accepts_already_snake_case
    assert_empty Andromeda::Frontmatter.non_snake_case_keys({ "already_snake" => 1 })
  end

  def test_non_snake_case_keys_accepts_digits_within_a_snake_case_key
    assert_empty Andromeda::Frontmatter.non_snake_case_keys({ "hero_image_2x" => 1 })
  end

  def test_non_snake_case_keys_flags_non_ascii_keys
    assert_equal ["日付"], Andromeda::Frontmatter.non_snake_case_keys({ "日付" => 1 })
  end

  def test_non_snake_case_keys_only_looks_at_top_level
    data = { "hero_image" => { "altText" => "ok nested" } }

    assert_empty Andromeda::Frontmatter.non_snake_case_keys(data)
  end

  def test_non_snake_case_keys_returns_all_offenders_in_order
    data = { "already_snake" => 1, "pubDate" => 2, "hero-image" => 3 }

    assert_equal %w[pubDate hero-image], Andromeda::Frontmatter.non_snake_case_keys(data)
  end

  # --- YAML 1.2 scalars, as js-yaml resolves them ---------------------------------

  def yaml_value(scalar)
    data, = Andromeda::Frontmatter.parse("---\nvalue: #{scalar}\n---\nbody\n")
    data["value"]
  end

  def test_base_60_and_comma_grouped_numbers_stay_strings
    assert_equal "12:30", yaml_value("12:30")
    assert_equal "1:30:15", yaml_value("1:30:15")
    assert_equal "1,000", yaml_value("1,000")
  end

  def test_leading_zero_integers_are_decimal_not_octal
    assert_equal 10, yaml_value("010")
    assert_equal 9, yaml_value("09")
    assert_equal(-10, yaml_value("-010"))
  end

  def test_0o_prefix_is_octal
    assert_equal 15, yaml_value("0o17")
  end

  def test_exponent_without_a_decimal_point_is_a_float
    assert_equal 1000.0, yaml_value("1e3")
    assert_equal(-0.02, yaml_value("-2E-2"))
    assert_equal 1000.0, yaml_value("1.e3")
    assert_equal 500.0, yaml_value(".5e3")
  end

  def test_scalars_both_versions_agree_on_are_unchanged
    assert_equal 31, yaml_value("0x1F")
    assert_equal 1000, yaml_value("1_000")
    assert_equal 0.5, yaml_value(".5")
    assert_equal "1.2.3", yaml_value("1.2.3")
    assert_equal "010", yaml_value('"010"'), "quoted scalars are never resolved"
  end

  # --- aliases ---------------------------------------------------------------------

  def test_ordinary_anchors_aliases_and_merge_keys_still_work
    data, = Andromeda::Frontmatter.parse(<<~MD)
      ---
      base: &base { lang: en }
      post:
        <<: *base
        title: Hi
      both: [*base, *base]
      ---
      body
    MD

    assert_equal({ "lang" => "en", "title" => "Hi" }, data["post"])
    assert_equal [{ "lang" => "en" }] * 2, data["both"]
  end

  def test_exponential_alias_expansion_is_rejected_before_it_is_expanded
    levels = ("a".."i").each_cons(2).map { |prev, cur| "#{cur}: &#{cur} [#{(["*#{prev}"] * 9).join(", ")}]" }
    yaml = "---\na: &a [#{(['"lol"'] * 9).join(", ")}]\n#{levels.join("\n")}\n---\nbody\n"

    error = assert_raises(Andromeda::SyntaxError) { Andromeda::Frontmatter.parse(yaml, path: "bomb.md") }
    assert_match(/aliases expand to more than/, error.message)
    assert_equal "bomb.md", error.path
  end
end
