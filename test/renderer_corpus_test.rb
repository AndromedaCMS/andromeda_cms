# frozen_string_literal: true

require "test_helper"

# Full-pipeline smoke test (frontmatter -> parser -> renderer) over the same
# real-world corpus test/corpus_test.rb parses -- see test/corpus/README.md
# for provenance. As with corpus_test.rb, the bar is "renders without
# raising and produces non-empty output", not byte-for-byte parity with
# Astro.
class RendererCorpusTest < Minitest::Test
  CORPUS_DIR = File.expand_path("corpus", __dir__)

  # Records every MDX component call so a corpus file that happens to use
  # components still renders (rather than raising MissingComponentError)
  # and so a broken delegation would show up as an empty/wrong children_html
  # rather than the test just skipping the file.
  class StubComponents
    attr_reader :calls

    def initialize
      @calls = []
    end

    def render(name, attrs, children_html, node)
      @calls << [name, attrs, children_html, node]
      "<div data-andromeda-component=\"#{name}\">#{children_html}</div>"
    end
  end

  Dir.glob("#{CORPUS_DIR}/*.{md,mdx}").sort.each do |path|
    basename = File.basename(path)
    mdx = Andromeda::Parser.mdx?(path)

    define_method(:"test_renders_#{basename.gsub(/[^a-zA-Z0-9]/, '_')}") do
      source = File.read(path)
      _data, body = Andromeda::Frontmatter.parse(source, path: path)

      tree = Andromeda::Parser.parse(body, mdx: mdx, path: path)
      components = StubComponents.new
      result = Andromeda::Renderer.new(components: components).render(tree)

      # A handful of real files are frontmatter-only (e.g. Starlight's
      # `404.md`, whose content lives entirely in frontmatter fields like
      # `hero.tagline`) -- empty HTML for an empty body is correct, not a
      # renderer bug, so only require non-empty output when there was
      # something to render in the first place.
      refute_empty result.html, "expected non-empty HTML for #{basename}" unless body.strip.empty?
      assert_kind_of Array, result.headings
    end
  end

  def test_corpus_is_not_empty
    refute_empty Dir.glob("#{CORPUS_DIR}/*.{md,mdx}")
  end
end
