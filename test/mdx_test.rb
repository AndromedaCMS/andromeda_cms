# frozen_string_literal: true

require "test_helper"

class MdxTest < Minitest::Test
  def test_md_mode_never_produces_mdx_nodes_even_for_jsx_looking_input
    tree = Andromeda::Parser.parse("<Component prop=\"x\">hi</Component>", mdx: false)
    types = collect_types(tree)

    refute(types.any? { |t| t.start_with?("mdx") })
    assert_includes types, "html"
  end

  def test_simple_component_with_string_prop
    tree = Andromeda::Parser.parse('<Badge text="new" />', mdx: true)
    element = tree[:children][0]

    assert_equal "mdxJsxFlowElement", element[:type]
    assert_equal "Badge", element[:name]
    assert_equal(
      [{ type: "mdxJsxAttribute", name: "text", value: "new" }],
      element[:attributes]
    )
  end

  def test_component_with_expression_prop
    tree = Andromeda::Parser.parse("<Counter count={1 + 1} />", mdx: true)
    attr = tree[:children][0][:attributes][0]

    assert_equal "mdxJsxAttribute", attr[:type]
    assert_equal "count", attr[:name]
    assert_equal({ type: "mdxJsxAttributeValueExpression", value: "1 + 1" }, attr[:value])
  end

  def test_component_with_boolean_prop
    tree = Andromeda::Parser.parse("<Toggle enabled />", mdx: true)
    attr = tree[:children][0][:attributes][0]

    assert_equal "enabled", attr[:name]
    assert_nil attr[:value]
  end

  def test_component_with_spread_prop
    tree = Andromeda::Parser.parse("<Widget {...props} />", mdx: true)
    attr = tree[:children][0][:attributes][0]

    assert_equal "mdxJsxExpressionAttribute", attr[:type]
    assert_equal "...props", attr[:value]
  end

  def test_self_closing_component_has_no_children_field
    tree = Andromeda::Parser.parse("<Spacer />", mdx: true)
    element = tree[:children][0]

    assert_equal [], element[:children]
  end

  def test_component_with_text_children
    tree = Andromeda::Parser.parse("<Note>hello world</Note>", mdx: true)
    element = tree[:children][0]

    assert_equal "hello world", element[:children][0][:value]
  end

  def test_nested_components
    tree = Andromeda::Parser.parse("<Outer><Inner>deep</Inner></Outer>", mdx: true)
    outer = tree[:children][0]
    inner = outer[:children][0]

    assert_equal "Outer", outer[:name]
    assert_equal "Inner", inner[:name]
    assert_equal "deep", inner[:children][0][:value]
  end

  def test_fragment_has_nil_name
    tree = Andromeda::Parser.parse("<>fragment text</>", mdx: true)
    fragment = tree[:children][0]

    assert_nil fragment[:name]
  end

  def test_esm_import
    tree = Andromeda::Parser.parse("import Foo from \"./foo.astro\"\n\nbody", mdx: true)
    esm = tree[:children][0]

    assert_equal "mdxjsEsm", esm[:type]
    assert_includes esm[:value], "import Foo"
  end

  def test_esm_export
    tree = Andromeda::Parser.parse("export const x = 1\n\nbody", mdx: true)
    esm = tree[:children][0]

    assert_equal "mdxjsEsm", esm[:type]
    assert_includes esm[:value], "export const x"
  end

  def test_flow_expression
    tree = Andromeda::Parser.parse("{1 + 1}", mdx: true)
    expr = tree[:children][0]

    assert_equal "mdxFlowExpression", expr[:type]
    assert_equal "1 + 1", expr[:value]
  end

  def test_text_expression_inside_paragraph
    tree = Andromeda::Parser.parse("The answer is {40 + 2}.", mdx: true)
    paragraph = tree[:children][0]
    expr = paragraph[:children].find { |n| n[:type] == "mdxTextExpression" }

    refute_nil expr
    assert_equal "40 + 2", expr[:value]
  end

  def test_expression_comment_is_an_expression_node
    tree = Andromeda::Parser.parse("{/* just a comment */}", mdx: true)
    expr = tree[:children][0]

    assert_equal "mdxFlowExpression", expr[:type]
    assert_equal "/* just a comment */", expr[:value]
  end

  def test_component_wrapping_markdown_content_still_parses_inline_markdown
    tree = Andromeda::Parser.parse("<Card>**bold** and a [link](/x)</Card>", mdx: true)
    card = tree[:children][0]
    types = card[:children].map { |n| n[:type] }

    assert_includes types, "strong"
    assert_includes types, "link"
  end

  def test_positions_present_on_mdx_nodes
    tree = Andromeda::Parser.parse("<Foo bar=\"1\">{expr}</Foo>", mdx: true)

    assert_all_positions_present(tree)
  end

  private

  def collect_types(node, out = [])
    case node
    when Hash
      out << node[:type] if node[:type]
      node.each_value { |v| collect_types(v, out) }
    when Array
      node.each { |n| collect_types(n, out) }
    end
    out
  end
end
