# frozen_string_literal: true

# Parses and renders a large body of real Astro content, as a regression net
# for Sätteri upgrades: the gem pins a pre-1.0 engine, so "still parses
# everything the ecosystem actually writes" is the property worth guarding.
#
# The corpus is fetched rather than vendored (thousands of files from other
# projects do not belong in a gem), which is why this lives outside the
# default test run. Use `rake test:corpus`.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "andromeda_cms"
require "json"

CORPUS_DIR = ENV.fetch("ANDROMEDA_CORPUS", File.expand_path("corpus_large", __dir__))

abort "no corpus at #{CORPUS_DIR} -- run test/fetch_corpus.sh first" unless Dir.exist?(CORPUS_DIR)

files = Dir["#{CORPUS_DIR}/**/*.{md,mdx}"].sort
abort "no content found under #{CORPUS_DIR}" if files.empty?

# Components are not the subject here; every tag resolves to the same stand-in
# so a missing partial cannot mask a parser regression.
stub_components = Class.new do
  def render(name, _attributes, children_html, _node) = "<div data-component=\"#{name}\">#{children_html}</div>"
  def evaluate_expression(*) = ""
end.new

failures = []
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

files.each do |path|
  source = File.read(path)
  _data, body = Andromeda::Frontmatter.parse(source, path: path)
  tree = Andromeda::Parser.parse(body, mdx: path.end_with?(".mdx"), path: path)
  html = Andromeda::Renderer.new(components: stub_components).render(tree).html
  failures << "#{path}: rendered empty" if html.strip.empty? && body.strip.length > 40
rescue StandardError => e
  failures << "#{path}: #{e.class}: #{e.message.lines.first.to_s.strip}"
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts format("corpus: %d files in %.1fs (%.2f ms/file)", files.size, elapsed, elapsed * 1000 / files.size)

if failures.empty?
  puts "corpus: no failures"
else
  failures.first(40).each { |failure| warn failure }
  abort "corpus: #{failures.size} of #{files.size} files failed"
end
