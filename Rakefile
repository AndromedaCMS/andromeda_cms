# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("andromeda_cms.gemspec")

RbSys::ExtensionTask.new("andromeda_cms", GEMSPEC) do |ext|
  # Matches extconf.rb's create_rust_makefile("andromeda_cms/andromeda_cms"),
  # so a built-from-source install and a local `rake compile` agree on where
  # the extension lives.
  ext.lib_dir = "lib/andromeda_cms"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

namespace :test do
  desc "Parse and render a large corpus of real Astro content (see test/fetch_corpus.sh)"
  task corpus: :compile do
    ruby "test/corpus_regression.rb"
  end
end

# Tests exercise the native parser, so they are meaningless without a fresh build.
task test: :compile

task default: %i[compile test]
