# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/andromeda/install/install_generator"

module Generators
  class InstallGeneratorTest < Rails::Generators::TestCase
    tests Andromeda::Generators::InstallGenerator
    destination File.expand_path("../../tmp/generators/install", __dir__)
    setup :prepare_destination

    test "creates the content and component directories with .keep files" do
      run_generator

      assert_directory "app/content"
      assert_file "app/content/.keep"
      assert_directory "app/views/content_components"
      assert_file "app/views/content_components/.keep"
    end

    test "creates an initializer commenting out every Configuration setting" do
      run_generator

      assert_file "config/initializers/andromeda.rb" do |content|
        assert_match(/Andromeda\.configure do \|config\|/, content)
        # Every attr_accessor on Andromeda::Configuration should be
        # represented, or a new setting could silently go undocumented here.
        %w[content_path entry_namespace components_path build_path highlight_theme mode].each do |setting|
          assert_match(/#\s*config\.#{setting}\s*=/, content, "expected a commented-out config.#{setting} line")
        end
      end
    end

    test "appends the ignore lines to an existing .gitignore and .dockerignore exactly once" do
      File.write(File.join(destination_root, ".gitignore"), "node_modules/\n")
      File.write(File.join(destination_root, ".dockerignore"), ".git\n")

      run_generator
      run_generator # idempotency: running twice must not duplicate the lines

      [".gitignore", ".dockerignore"].each do |filename|
        assert_file filename do |content|
          assert_equal 1, content.scan("/.andromeda/").size, "#{filename}: /.andromeda/ should appear exactly once"
          assert_equal 1, content.scan("/app/assets/builds/andromeda/").size,
                       "#{filename}: the builds path should appear exactly once"
        end
      end
    end

    test "leaves original .gitignore content untouched" do
      File.write(File.join(destination_root, ".gitignore"), "node_modules/\n")

      run_generator

      assert_file ".gitignore", /node_modules\//
    end

    test "starts on a new line when the last line of .gitignore/.dockerignore has no newline" do
      File.write(File.join(destination_root, ".gitignore"), "/public/sitemap.xml.gz")
      File.write(File.join(destination_root, ".dockerignore"), ".git")

      run_generator

      assert_file ".gitignore", "/public/sitemap.xml.gz\n/.andromeda/\n/app/assets/builds/andromeda/\n"
      assert_file ".dockerignore", ".git\n/.andromeda/\n/app/assets/builds/andromeda/\n"
    end

    test "explains itself instead of inventing .gitignore/.dockerignore when they don't exist" do
      output = run_generator

      assert_no_file ".gitignore"
      assert_no_file ".dockerignore"
      assert_match(/\.gitignore not found/, output)
      assert_match(/\.dockerignore not found/, output)
    end

    test "prints next steps mentioning both the collection and import_astro generators" do
      output = run_generator

      assert_match(/andromeda:collection/, output)
      assert_match(/andromeda:import_astro/, output)
    end
  end
end
