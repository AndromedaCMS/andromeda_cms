# frozen_string_literal: true

require "rouge"

module Andromeda
  class Renderer
    # Stands in for Shiki: matches the *markup shape*
    # Astro/Shiki produce for fenced code blocks -- `<pre class="astro-code
    # <theme>" style="..." data-language="...">` -- so existing CSS written
    # against Astro's default output keeps working, while the actual colours
    # come from Rouge instead of Shiki (a byte-identical palette is not the
    # goal -- displaying the code correctly is, not matching Shiki exactly).
    module CodeHighlighter
      # `github.dark` is Rouge's built-in theme closest to Shiki's default
      # `github-dark` (same source palette family: GitHub's dark code theme),
      # and it keeps the CSS class name Astro emits (`astro-code github-dark`)
      # meaningful rather than mismatched with the actual colours.
      THEME_NAME = "github-dark"
      THEME = Rouge::Theme.find("github.dark").new
      FORMATTER = Rouge::Formatters::HTMLInline.new(THEME)
      BACKGROUND = THEME.palette[:bgDefault]
      FOREGROUND = THEME.palette[:fgDefault]

      module_function

      # @param code [String] the fenced code block's body (already the raw
      #   text -- mdast `code` nodes store it unescaped).
      # @param lang [String, nil] the fence's language tag, if any.
      # @return [String] a full `<pre>...</pre>` element.
      def render(code, lang)
        lexer = lookup_lexer(lang)
        body = lexer ? FORMATTER.format(lexer.lex(code)) : Renderer.escape_html(code)

        # Shiki/Astro emit `data-language` verbatim from the fence even when
        # the language is not one Shiki recognizes (it would raise instead);
        # Rouge is more permissive about *finding* a lexer but we still fall
        # back to plain text for anything it can't find, per this step's
        # brief ("falls back to plain text without raising") -- so an
        # unrecognized `lang` keeps its `data-language` label for styling
        # purposes even though no syntax highlighting was applied.
        language_attr = lang && !lang.empty? ? %( data-language="#{Renderer.escape_attr(lang)}") : ""

        %(<pre class="astro-code #{THEME_NAME}" style="background-color:#{BACKGROUND};color:#{FOREGROUND};overflow-x:auto;"#{language_attr}><code>#{body}</code></pre>)
      end

      def lookup_lexer(lang)
        return nil if lang.nil? || lang.empty?

        Rouge::Lexer.find(lang.downcase)
      end
    end
  end
end
