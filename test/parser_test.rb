# frozen_string_literal: true

require "test_helper"

class ParserTest < Minitest::Test
  def test_reports_the_backend_it_was_built_against
    assert_equal "satteri", Andromeda::Parser.backend
  end

  def test_parses_an_empty_document
    tree = Andromeda::Parser.parse("")

    assert_equal({ type: "root", children: [] }, strip_positions(tree))
  end

  def test_root_and_paragraph_and_text
    tree = Andromeda::Parser.parse("Hello world")

    assert_equal(
      {
        type: "root",
        children: [
          { type: "paragraph", children: [{ type: "text", value: "Hello world" }] },
        ],
      },
      strip_positions(tree)
    )
  end

  def test_heading_depth
    tree = Andromeda::Parser.parse("### Three")
    heading = tree[:children][0]

    assert_equal "heading", heading[:type]
    assert_equal 3, heading[:depth]
  end

  def test_emphasis_strong_and_inline_code
    tree = Andromeda::Parser.parse("*em* **strong** `code`")
    paragraph = strip_positions(tree[:children][0])

    assert_equal "emphasis", paragraph[:children][0][:type]
    assert_equal "strong", paragraph[:children][2][:type]
    assert_equal({ type: "inlineCode", value: "code" }, paragraph[:children][4])
  end

  def test_thematic_break
    # A leading "---" is YAML-frontmatter syntax (ENABLE_YAML_STYLE_METADATA_BLOCKS
    # is on, matching Astro); put content before it so this exercises the
    # thematicBreak rule instead.
    tree = Andromeda::Parser.parse("above\n\n---\n\nbelow")

    types = tree[:children].map { |n| n[:type] }
    assert_includes types, "thematicBreak"
  end

  def test_hard_line_break
    tree = Andromeda::Parser.parse("line one  \nline two")
    paragraph = strip_positions(tree[:children][0])

    assert_equal "break", paragraph[:children][1][:type]
  end

  def test_blockquote_nesting
    tree = Andromeda::Parser.parse("> quoted **text**")
    blockquote = strip_positions(tree[:children][0])

    assert_equal "blockquote", blockquote[:type]
    assert_equal "paragraph", blockquote[:children][0][:type]
  end

  def test_link_with_title
    tree = Andromeda::Parser.parse('[text](https://example.com "a title")')
    link = strip_positions(tree[:children][0][:children][0])

    assert_equal(
      { type: "link", url: "https://example.com", title: "a title", children: [{ type: "text", value: "text" }] },
      link
    )
  end

  def test_link_without_title_has_nil_title
    tree = Andromeda::Parser.parse("[text](https://example.com)")
    link = tree[:children][0][:children][0]

    assert_nil link[:title]
  end

  def test_image_with_alt_and_title
    tree = Andromeda::Parser.parse('![alt text](/img.png "a title")')
    image = strip_positions(tree[:children][0][:children][0])

    assert_equal({ type: "image", url: "/img.png", alt: "alt text", title: "a title" }, image)
  end

  def test_reference_style_link_and_definition
    tree = Andromeda::Parser.parse("[text][ref]\n\n[ref]: https://example.com \"Title\"")
    paragraph = strip_positions(tree[:children][0])
    reference = paragraph[:children][0]

    assert_equal "linkReference", reference[:type]
    assert_equal "ref", reference[:identifier]
    assert_equal "full", reference[:referenceType]

    definition = strip_positions(tree[:children][1])
    assert_equal(
      { type: "definition", url: "https://example.com", title: "Title", identifier: "ref", label: "ref" },
      definition
    )
  end

  def test_shortcut_reference_style
    tree = Andromeda::Parser.parse("[ref]\n\n[ref]: https://example.com")
    reference = tree[:children][0][:children][0]

    assert_equal "shortcut", reference[:referenceType]
  end

  def test_image_reference
    tree = Andromeda::Parser.parse("![alt][ref]\n\n[ref]: /img.png")
    reference = tree[:children][0][:children][0]

    assert_equal "imageReference", reference[:type]
    assert_equal "alt", reference[:alt]
  end

  def test_fenced_code_block_with_lang_and_meta
    tree = Andromeda::Parser.parse("```ruby title=\"a.rb\"\nputs 1\n```")
    code = tree[:children][0]

    assert_equal "code", code[:type]
    assert_equal "ruby", code[:lang]
    assert_equal 'title="a.rb"', code[:meta]
    assert_equal "puts 1", code[:value]
  end

  def test_code_block_without_lang_has_nil_lang_and_meta
    tree = Andromeda::Parser.parse("```\nplain\n```")
    code = tree[:children][0]

    assert_nil code[:lang]
    assert_nil code[:meta]
  end

  def test_indented_code_block
    tree = Andromeda::Parser.parse("    indented code\n")
    code = tree[:children][0]

    assert_equal "code", code[:type]
    assert_equal "indented code", code[:value]
  end

  def test_unordered_list
    tree = Andromeda::Parser.parse("- one\n- two\n")
    list = tree[:children][0]

    assert_equal "list", list[:type]
    assert_equal false, list[:ordered]
    assert_nil list[:start]
    assert_equal 2, list[:children].size
  end

  def test_ordered_list_with_custom_start
    tree = Andromeda::Parser.parse("5. five\n6. six\n")
    list = tree[:children][0]

    assert_equal true, list[:ordered]
    assert_equal 5, list[:start]
  end

  def test_loose_list_is_spread
    tree = Andromeda::Parser.parse("- one\n\n- two\n")
    list = tree[:children][0]

    assert_equal true, list[:spread]
  end

  def test_tight_list_is_not_spread
    tree = Andromeda::Parser.parse("- one\n- two\n")
    list = tree[:children][0]

    assert_equal false, list[:spread]
  end

  def test_task_list_items_are_checked_or_unchecked
    tree = Andromeda::Parser.parse("- [ ] todo\n- [x] done\n")
    items = tree[:children][0][:children]

    assert_equal false, items[0][:checked]
    assert_equal true, items[1][:checked]
  end

  def test_plain_list_item_checked_is_nil
    tree = Andromeda::Parser.parse("- not a task\n")
    item = tree[:children][0][:children][0]

    assert_nil item[:checked]
  end

  def test_strikethrough_gfm
    tree = Andromeda::Parser.parse("~~gone~~")
    delete = tree[:children][0][:children][0]

    assert_equal "delete", delete[:type]
    assert_equal "gone", delete[:children][0][:value]
  end

  def test_gfm_table_with_alignment
    src = "| A | B | C |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n"
    tree = Andromeda::Parser.parse(src)
    table = tree[:children][0]

    assert_equal "table", table[:type]
    assert_equal %w[left center right], table[:align]
    assert_equal "tableRow", table[:children][0][:type]
    assert_equal "tableCell", table[:children][0][:children][0][:type]
  end

  def test_footnote_reference_and_definition
    src = "A note.[^1]\n\n[^1]: The footnote body.\n"
    tree = Andromeda::Parser.parse(src)
    reference = tree[:children][0][:children][1]
    definition = tree[:children][1]

    assert_equal "footnoteReference", reference[:type]
    assert_equal "1", reference[:identifier]
    assert_equal "footnoteDefinition", definition[:type]
    assert_equal "1", definition[:identifier]
  end

  def test_yaml_frontmatter
    src = "---\ntitle: Hello\ndraft: false\n---\n\nBody text\n"
    tree = Andromeda::Parser.parse(src)
    frontmatter = tree[:children][0]

    assert_equal "yaml", frontmatter[:type]
    assert_equal "title: Hello\ndraft: false", frontmatter[:value]
  end

  # Astro's default engine only recognizes YAML frontmatter (`---`); TOML
  # frontmatter (`+++`) needs Sätteri's ENABLE_PLUSES_DELIMITED_METADATA_BLOCKS,
  # which is intentionally not enabled here (see ext/andromeda_cms/src/lib.rs
  # `options_for`) since Astro itself doesn't turn it on. `+++` therefore
  # parses as ordinary paragraph text, matching what Astro would actually do
  # with such a file — locking this in so a future options change is a
  # deliberate decision, not an accidental regression.
  def test_toml_delimited_frontmatter_is_not_recognized_by_default
    src = "+++\ntitle = \"Hello\"\n+++\n\nBody\n"
    tree = Andromeda::Parser.parse(src)

    refute_equal "toml", tree[:children][0][:type]
    assert_equal "paragraph", tree[:children][0][:type]
  end

  def test_raw_html_block
    tree = Andromeda::Parser.parse("<div class=\"x\">\n  <p>raw</p>\n</div>\n")
    html = tree[:children][0]

    assert_equal "html", html[:type]
    assert_includes html[:value], "<div"
  end

  def test_inline_raw_html
    tree = Andromeda::Parser.parse("before <br/> after")
    paragraph = tree[:children][0]

    assert(paragraph[:children].any? { |n| n[:type] == "html" && n[:value] == "<br/>" })
  end

  def test_japanese_and_emoji_content
    src = "# 見出し\n\n本文には日本語と絵文字 🎉 が含まれます。\n"
    tree = Andromeda::Parser.parse(src)
    heading = tree[:children][0]
    paragraph = tree[:children][1]

    assert_equal "heading", heading[:type]
    assert_equal "見出し", heading[:children][0][:value]
    assert_includes paragraph[:children][0][:value], "🎉"
  end

  def test_position_present_on_every_node_for_a_representative_document
    src = <<~MD
      # Heading

      A [link](https://example.com) and *em* and `code`.

      - [ ] item

      | a | b |
      |---|---|
      | 1 | 2 |
    MD
    tree = Andromeda::Parser.parse(src)

    assert_all_positions_present(tree)
  end

  def test_position_line_and_column_are_1_based_and_utf16_aware
    # "日本語" is 3 code units in UTF-16 (BMP), so the emoji after it starts
    # at column 1 (heading marker "# ") + 3 (kanji) + 1 (space) + 1 = column 6,
    # and spans 2 UTF-16 code units (astral character).
    tree = Andromeda::Parser.parse("# 日本語 🎉")
    text = tree[:children][0][:children][0]

    assert_equal 1, text[:position][:start][:line]
    assert_equal 3, text[:position][:start][:column]
  end

  def test_backslash_escapes_are_resolved_in_text
    tree = Andromeda::Parser.parse("\\*not emphasis\\*")
    text = tree[:children][0][:children][0]

    assert_equal "*not emphasis*", text[:value]
  end
end
