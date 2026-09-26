# frozen_string_literal: true

require "test_helper"

# Smoke test over a small real-world corpus (see test/corpus/README.md for
# provenance). The bar here is deliberately low — "parses without raising" —
# because the project's compatibility goal is "MD/MDX loads and renders
# without error", not byte-for-byte parity with remark.
class CorpusTest < Minitest::Test
  CORPUS_DIR = File.expand_path("corpus", __dir__)

  Dir.glob("#{CORPUS_DIR}/*.{md,mdx}").sort.each do |path|
    basename = File.basename(path)
    mdx = Andromeda::Parser.mdx?(path)

    define_method(:"test_parses_#{basename.gsub(/[^a-zA-Z0-9]/, '_')}") do
      source = File.read(path)

      tree = Andromeda::Parser.parse(source, mdx: mdx, path: path)

      assert_equal "root", tree[:type]
      assert_all_positions_present(tree)
    end
  end

  def test_corpus_is_not_empty
    # Guards against a silently-broken glob (e.g. a typo'd directory) making
    # every generated test above vacuously skip.
    refute_empty Dir.glob("#{CORPUS_DIR}/*.{md,mdx}")
  end
end
