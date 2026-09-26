# frozen_string_literal: true

require "test_helper"

class ComponentsStaticExpressionTest < Minitest::Test
  StaticExpression = Andromeda::Components::StaticExpression

  def test_string_literal
    assert_equal "hi", StaticExpression.evaluate('"hi"')
  end

  def test_number_literal
    assert_equal 42, StaticExpression.evaluate("42")
  end

  def test_boolean_literal
    assert_equal true, StaticExpression.evaluate("true")
  end

  def test_array_literal
    assert_equal %w[a b], StaticExpression.evaluate('["a", "b"]')
  end

  def test_object_literal
    assert_equal({ "a" => 1 }, StaticExpression.evaluate("{a: 1}"))
  end

  def test_comment_evaluates_to_empty_string
    assert_equal "", StaticExpression.evaluate("/* a comment */")
  end

  def test_frontmatter_top_level_reference
    assert_equal "Hello", StaticExpression.evaluate("frontmatter.title", frontmatter: { title: "Hello" })
  end

  def test_frontmatter_nested_reference
    value = StaticExpression.evaluate("frontmatter.author.name", frontmatter: { author: { name: "Ada" } })
    assert_equal "Ada", value
  end

  def test_frontmatter_reference_accepts_string_keyed_hash
    assert_equal "Hello", StaticExpression.evaluate("frontmatter.title", frontmatter: { "title" => "Hello" })
  end

  def test_missing_frontmatter_key_is_nil_not_an_error
    assert_nil StaticExpression.evaluate("frontmatter.missing", frontmatter: { title: "Hello" })
  end

  def test_non_literal_non_frontmatter_expression_raises
    assert_raises(StaticExpression::UnsupportedExpressionError) do
      StaticExpression.evaluate("1 + 1")
    end
  end

  def test_function_call_raises
    assert_raises(StaticExpression::UnsupportedExpressionError) do
      StaticExpression.evaluate("items.map(x => x)")
    end
  end

  def test_frontmatter_itself_without_a_property_raises
    assert_raises(StaticExpression::UnsupportedExpressionError) do
      StaticExpression.evaluate("frontmatter")
    end
  end
end
