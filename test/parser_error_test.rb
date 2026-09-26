# frozen_string_literal: true

require "test_helper"

class ParserErrorTest < Minitest::Test
  def test_unclosed_jsx_tag_raises_syntax_error_with_line_and_column
    error = assert_raises(Andromeda::SyntaxError) do
      Andromeda::Parser.parse("<Callout>never closed", mdx: true)
    end

    assert_kind_of Integer, error.line
    assert_kind_of Integer, error.column
    assert_equal 1, error.line
    assert_nil error.path
  end

  def test_syntax_error_message_includes_location_without_path
    error = assert_raises(Andromeda::SyntaxError) do
      Andromeda::Parser.parse("<Callout>never closed", mdx: true)
    end

    assert_match(/\A\d+:\d+: /, error.message)
  end

  def test_syntax_error_carries_path_when_given
    error = assert_raises(Andromeda::SyntaxError) do
      Andromeda::Parser.parse("<Callout>never closed", mdx: true, path: "app/content/blog/x.mdx")
    end

    assert_equal "app/content/blog/x.mdx", error.path
    assert error.message.start_with?("app/content/blog/x.mdx:#{error.line}:#{error.column}: "),
           "expected path:line:column: prefix, got: #{error.message}"
    # The underlying Sätteri message must survive path-rewriting verbatim
    # (regression guard for the prefix-stripping in Andromeda::Parser.with_path).
    assert_includes error.message, "Callout"
  end

  def test_syntax_error_is_an_andromeda_error
    assert_operator Andromeda::SyntaxError, :<, Andromeda::Error
  end

  def test_mismatched_jsx_attribute_braces_raise_syntax_error
    assert_raises(Andromeda::SyntaxError) do
      Andromeda::Parser.parse("<Foo bar={unterminated>hi</Foo>", mdx: true)
    end
  end

  def test_unterminated_expression_raises_syntax_error
    assert_raises(Andromeda::SyntaxError) do
      Andromeda::Parser.parse("{unterminated", mdx: true)
    end
  end

  def test_empty_string_does_not_raise
    tree = Andromeda::Parser.parse("")

    assert_equal "root", tree[:type]
    assert_empty tree[:children]
  end

  def test_whitespace_only_document_does_not_raise
    tree = Andromeda::Parser.parse("   \n\n\t\n")

    assert_equal "root", tree[:type]
  end

  def test_very_large_document_does_not_crash
    # ~1MB of Markdown: enough paragraphs that a naive recursive-descent
    # implementation with no tail-call optimization could blow the stack;
    # this is the regression test for that class of native panic.
    paragraph = "Lorem ipsum dolor sit amet, #{'x' * 40} consectetur.\n\n"
    huge = paragraph * (1_000_000 / paragraph.bytesize)

    assert_operator huge.bytesize, :>, 900_000

    tree = Andromeda::Parser.parse(huge)

    assert_equal "root", tree[:type]
    refute_empty tree[:children]
  end

  def test_deeply_nested_blockquotes_do_not_crash
    # Another shape of pathological input: deep recursion via nesting rather
    # than sheer size. Kept well under JSON's own recursion limits on the
    # decode side (see Andromeda::Parser.parse's max_nesting: false) so this
    # isolates the *native parser's* recursion handling specifically.
    nested = ("> " * 60) + "bottom"

    tree = Andromeda::Parser.parse(nested)

    assert_equal "root", tree[:type]
  end

  def test_parser_error_is_an_andromeda_error
    assert_operator Andromeda::ParserError, :<, Andromeda::Error
  end


  # --- nesting limits ----------------------------------------------------------------

  def test_nesting_beyond_the_limit_is_a_syntax_error_with_a_location
    error = assert_raises(Andromeda::SyntaxError) do
      Andromeda::Parser.parse("intro\n\n#{">" * 300} deep\n", path: "deep.md")
    end

    assert_match(/nested more than 256 levels/, error.message)
    assert_equal 3, error.line
    assert_equal "deep.md", error.path
  end

  def test_nesting_within_the_limit_parses
    tree = Andromeda::Parser.parse("#{"> " * 100}bottom\n")

    assert_equal "blockquote", tree[:children].first[:type]
  end

  # Puma serves development requests on threads with a far smaller stack
  # than the main thread; the limits must hold there too.
  %w[quote list jsx emphasis].each do |shape|
    define_method("test_pathological_#{shape}_nesting_fails_cleanly_on_a_non_main_thread") do
      source, mdx =
        case shape
        when "quote" then [">" * 50_000, false]
        when "list" then ["- " * 20_000 + "x", false]
        when "jsx" then ["<div>" * 50_000, true]
        when "emphasis" then ["*" * 100_000 + "x" + "*" * 100_000, false]
        end

      error = Thread.new do
        Andromeda::Parser.parse(source, mdx: mdx)
        nil
      rescue Andromeda::Error => e
        e
      end.value

      assert_kind_of Andromeda::SyntaxError, error
    end
  end

  def test_long_delimiter_runs_that_real_content_uses_still_parse
    tree = Andromeda::Parser.parse("#{"*" * 3}\n\n#{"_" * 80}\n\n#{"-" * 20_000}\n")

    refute_empty tree[:children]
  end
end
