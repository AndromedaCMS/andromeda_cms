# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/andromeda/component/component_generator"

module Generators
  class ComponentGeneratorTest < Rails::Generators::TestCase
    tests Andromeda::Generators::ComponentGenerator
    destination File.expand_path("../../tmp/generators/component", __dir__)
    setup :prepare_destination

    test "Callout with type and title props" do
      run_generator ["Callout", "type", "title"]

      assert_file "app/views/content_components/_callout.html.erb" do |content|
        assert_match(/<%# MDX usage:/, content)
        assert_match(/<Callout type="\.\.\." title="\.\.\.">/, content)
        assert_match(/<%# locals: \(type: nil, title: nil, content: nil\) %>/, content)
        assert_match(/<% if local_assigns\[:type\] %>.*<%= type %>/, content)
        assert_match(/<% if local_assigns\[:title\] %>.*<%= title %>/, content)
        assert_match(/<%= content %>/, content)
      end
    end

    test "a dotted name is rejected with a clear message" do
      error = assert_raises(ArgumentError) { run_generator ["Foo.Bar"] }

      assert_match(/invalid component name/, error.message)
      assert_no_file "app/views/content_components/_foo.bar.html.erb"
    end

    test "an underscored input produces the same result as CamelCase" do
      run_generator ["link_button", "url"]
      underscored_content = File.read(File.join(destination_root, "app/views/content_components/_link_button.html.erb"))

      prepare_destination
      run_generator ["LinkButton", "url"]
      camel_content = File.read(File.join(destination_root, "app/views/content_components/_link_button.html.erb"))

      assert_equal underscored_content, camel_content
      assert_match(/<LinkButton url="\.\.\.">/, underscored_content)
    end

    test "no props still renders content only" do
      run_generator ["Note"]

      assert_file "app/views/content_components/_note.html.erb" do |content|
        assert_match(/<Note>/, content)
        assert_match(/<%# locals: \(content: nil\) %>/, content)
        assert_match(/<%= content %>/, content)
        refute_match(/local_assigns/, content)
      end
    end
  end
end
